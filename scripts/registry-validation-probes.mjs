#!/usr/bin/env node
// Registry validation probes: what does the npm publish endpoint
// recompute server-side vs accept verbatim from the publisher?
//
// Probes (each on a unique 1.0.0-vprobe-<id>-<ts> version slot):
//   1. wrong dist.shasum (sha1)            — should reveal the race-condition bug at single-publish level
//   2. wrong dist.integrity (sha512)       — same question for sha512
//   3. lied fileCount                      — registry should override server-side
//   4. lied unpackedSize                   — registry should override server-side
//   5. manifest version != package.json    — registry should reject

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

function buildTarball(version, { internalVersion } = {}) {
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gh-probe-'))
  const pkgDir = path.join(stagingDir, 'package')
  fs.mkdirSync(pkgDir)
  fs.writeFileSync(
    path.join(pkgDir, 'package.json'),
    JSON.stringify({
      name: PKG,
      version: internalVersion ?? version,
      description: 'registry validation probe',
      main: 'index.js',
      license: 'MIT',
    }, null, 2),
  )
  fs.writeFileSync(path.join(pkgDir, 'index.js'), `module.exports = { ts: ${TS}, version: ${JSON.stringify(version)} };\n`)
  const tarballPath = path.join(stagingDir, `${PKG}-${version}.tgz`)
  execSync(`tar --no-xattrs --format=ustar -czf "${tarballPath}" -C "${stagingDir}" package`, { stdio: 'inherit' })
  const buf = fs.readFileSync(tarballPath)
  return {
    buf,
    sha1: crypto.createHash('sha1').update(buf).digest('hex'),
    integrity: `sha512-${crypto.createHash('sha512').update(buf).digest('base64')}`,
  }
}

async function publish({ version, manifestOverrides = {}, asTagDistinct = true }) {
  const { buf, sha1, integrity } = buildTarball(version, manifestOverrides.internalVersion ? { internalVersion: manifestOverrides.internalVersion } : {})

  const tgzName = `${PKG}-${version}.tgz`
  const dist = {
    tarball: `${REGISTRY}/${PKG}/-/${tgzName}`,
    shasum: manifestOverrides.shasum ?? sha1,
    integrity: manifestOverrides.integrity ?? integrity,
  }

  const versionManifest = {
    name: PKG,
    version,
    description: 'registry validation probe',
    main: 'index.js',
    license: 'MIT',
    _id: `${PKG}@${version}`,
    dist,
  }
  if (manifestOverrides.fileCount !== undefined) versionManifest.fileCount = manifestOverrides.fileCount
  if (manifestOverrides.unpackedSize !== undefined) versionManifest.unpackedSize = manifestOverrides.unpackedSize

  const body = {
    _id: PKG,
    name: PKG,
    description: 'probe',
    'dist-tags': asTagDistinct ? { 'probe': version } : { 'latest-probe': version },
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
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      accept: '*/*',
    },
    body: JSON.stringify(body),
  })
  const text = await res.text()
  const elapsed = Date.now() - t0

  return { res, text, elapsed, sentDist: dist, sentSha1: sha1, sentIntegrity: integrity, sentLength: buf.length }
}

async function readManifest(version) {
  const r = await fetch(`${REGISTRY}/${PKG}/${version}`, { headers: { accept: 'application/json' } })
  if (!r.ok) return { ok: false, status: r.status, body: await r.text() }
  return { ok: true, manifest: await r.json() }
}

async function probeCdnLength(version) {
  const r = await fetch(`${REGISTRY}/${PKG}/-/${PKG}-${version}.tgz`, { method: 'HEAD' })
  return { status: r.status, contentLength: r.headers.get('content-length') }
}

function logHeader(title) {
  console.log('\n' + '='.repeat(72))
  console.log(title)
  console.log('='.repeat(72))
}

const REPORT = []
function record(name, sent, registryStored, verdict) {
  REPORT.push({ name, sent, registryStored, verdict })
}

// ---- Probe 1: wrong dist.shasum ----
{
  logHeader('PROBE 1 — wrong dist.shasum (sha1)')
  const v = `1.0.0-vprobe-shasum-${TS}`
  const fakeShasum = '0000000000000000000000000000000000000000'
  const out = await publish({ version: v, manifestOverrides: { shasum: fakeShasum } })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms) — body: ${out.text.slice(0, 200)}`)
  console.log(`  real sha1: ${out.sentSha1}`)
  console.log(`  sent sha1: ${fakeShasum}`)
  await sleep(2000)
  const m = await readManifest(v)
  if (m.ok) {
    console.log(`  manifest dist.shasum:    ${m.manifest.dist?.shasum}`)
    console.log(`  manifest dist.integrity: ${m.manifest.dist?.integrity?.slice(0, 50)}...`)
    const accepted = m.manifest.dist?.shasum === fakeShasum
    record('shasum-injection', fakeShasum, m.manifest.dist?.shasum, accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN')
  } else {
    record('shasum-injection', fakeShasum, '<error>', `REJECTED: ${m.status} ${m.body}`)
  }
}

// ---- Probe 2: wrong dist.integrity ----
{
  logHeader('PROBE 2 — wrong dist.integrity (sha512)')
  const v = `1.0.0-vprobe-integrity-${TS}`
  const fakeIntegrity = `sha512-${'A'.repeat(86)}==`  // 64 raw bytes -> 88 b64 chars
  const out = await publish({ version: v, manifestOverrides: { integrity: fakeIntegrity } })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms) — body: ${out.text.slice(0, 200)}`)
  console.log(`  real integrity: ${out.sentIntegrity.slice(0, 50)}...`)
  console.log(`  sent integrity: ${fakeIntegrity.slice(0, 50)}...`)
  await sleep(2000)
  const m = await readManifest(v)
  if (m.ok) {
    console.log(`  manifest dist.integrity: ${m.manifest.dist?.integrity?.slice(0, 50)}...`)
    const accepted = m.manifest.dist?.integrity === fakeIntegrity
    record('integrity-injection', fakeIntegrity.slice(0, 30) + '...', (m.manifest.dist?.integrity || '').slice(0, 30) + '...', accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN')
  } else {
    record('integrity-injection', fakeIntegrity, '<error>', `REJECTED: ${m.status} ${m.body}`)
  }
}

// ---- Probe 3: lied fileCount ----
{
  logHeader('PROBE 3 — lied fileCount (sent 999)')
  const v = `1.0.0-vprobe-fc-${TS}`
  const out = await publish({ version: v, manifestOverrides: { fileCount: 999 } })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms) — body: ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(v)
  if (m.ok) {
    console.log(`  manifest fileCount:   ${m.manifest.fileCount}`)
    console.log(`  manifest unpackedSize: ${m.manifest.unpackedSize}`)
    const accepted = m.manifest.fileCount === 999
    record('fileCount-injection', 999, m.manifest.fileCount, accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN')
  } else {
    record('fileCount-injection', 999, '<error>', `REJECTED: ${m.status} ${m.body}`)
  }
}

// ---- Probe 4: lied unpackedSize ----
{
  logHeader('PROBE 4 — lied unpackedSize (sent 999_999_999)')
  const v = `1.0.0-vprobe-us-${TS}`
  const out = await publish({ version: v, manifestOverrides: { unpackedSize: 999_999_999 } })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms) — body: ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(v)
  if (m.ok) {
    console.log(`  manifest unpackedSize: ${m.manifest.unpackedSize}`)
    const accepted = m.manifest.unpackedSize === 999_999_999
    record('unpackedSize-injection', 999_999_999, m.manifest.unpackedSize, accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN')
  } else {
    record('unpackedSize-injection', 999_999_999, '<error>', `REJECTED: ${m.status} ${m.body}`)
  }
}

// ---- Probe 5: manifest version != tarball internal package.json version ----
{
  logHeader('PROBE 5 — manifest version != package.json version (mismatch consistency)')
  const v = `1.0.0-vprobe-vermismatch-${TS}`
  const otherV = `9.9.9-internal-${TS}`
  const out = await publish({ version: v, manifestOverrides: { internalVersion: otherV } })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms) — body: ${out.text.slice(0, 300)}`)
  await sleep(2000)
  const m = await readManifest(v)
  if (m.ok) {
    console.log(`  manifest.version: ${m.manifest.version}`)
    record('version-mismatch', `manifest=${v} vs pkg.json=${otherV}`, m.manifest.version, 'ACCEPTED — registry did NOT validate consistency')
  } else {
    record('version-mismatch', `manifest=${v} vs pkg.json=${otherV}`, '<error>', `REJECTED: ${m.status} ${m.body.slice(0, 200)}`)
  }
}

// ---- Summary table ----
logHeader('SUMMARY')
console.log()
console.log('| Field                    | Sent                              | Registry stored                   | Verdict |')
console.log('|--------------------------|-----------------------------------|-----------------------------------|---------|')
for (const r of REPORT) {
  const sent = String(r.sent).padEnd(33).slice(0, 33)
  const stored = String(r.registryStored).padEnd(33).slice(0, 33)
  console.log(`| ${r.name.padEnd(24)} | ${sent} | ${stored} | ${r.verdict} |`)
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)) }
