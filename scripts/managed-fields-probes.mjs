#!/usr/bin/env node
// Managed-field injection probes: do publisher-supplied values for fields
// the registry is supposed to "manage" get accepted, overridden, or rejected?
//
// Each probe uses a unique 1.0.0-mfprobe-<id>-<ts> version slot.

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execSync } from 'node:child_process'

const REGISTRY = 'https://registry.npmjs.org'
const PKG = 'ghostpublish'
const TS = Math.floor(Date.now() / 1000)

const SENTINEL = {
  npmUser:  { name: 'PROBE_FAKE_npmUser', email: 'probe-npmuser@example.invalid' },
  maintainer: { name: 'PROBE_FAKE_maintainer', email: 'probe-maint@example.invalid' },
  id: 'PROBE_FAKE_id_NOT_REAL',
  opInternal: { host: 'PROBE_FAKE_HOST_s3://fake-bucket', tmp: 'PROBE_FAKE_TMP/probe' },
  nodeVersion: 'PROBE_FAKE_node_v999',
  npmVersion: 'PROBE_FAKE_npm_v999',
  resolved: 'https://example.invalid/PROBE_FAKE_resolved.tgz',
  gitHead: 'PROBE_FAKE_GIT_HEAD_0000000000',
}

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
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gh-mfprobe-'))
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

async function publish(name, manifestExtras, topLevelExtras = {}) {
  const version = `1.0.0-mfprobe-${name}-${TS}`
  const { buf, sha1, integrity } = buildTarball(version)
  const tgzName = `${PKG}-${version}.tgz`

  const versionManifest = {
    name: PKG,
    version,
    license: 'MIT',
    main: 'index.js',
    _id: `${PKG}@${version}`,
    dist: {
      tarball: `${REGISTRY}/${PKG}/-/${tgzName}`,
      shasum: sha1,
      integrity,
    },
    ...manifestExtras,
  }

  const body = {
    _id: PKG,
    name: PKG,
    description: 'managed-fields probe',
    'dist-tags': { [`mfprobe-${name}`]: version },
    versions: { [version]: versionManifest },
    _attachments: {
      [tgzName]: {
        content_type: 'application/octet-stream',
        data: buf.toString('base64'),
        length: buf.length,
      },
    },
    ...topLevelExtras,
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

// ---- Probe A: _npmUser injection ----
{
  logHeader('PROBE A — _npmUser identity-spoofing attempt')
  const out = await publish('npmuser', { _npmUser: SENTINEL.npmUser })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest._npmUser: ${JSON.stringify(m.manifest._npmUser)}`)
    const accepted = m.manifest._npmUser?.name === SENTINEL.npmUser.name
    record('_npmUser', JSON.stringify(SENTINEL.npmUser).slice(0, 50), JSON.stringify(m.manifest._npmUser), accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN', out.res.status)
  } else {
    record('_npmUser', JSON.stringify(SENTINEL.npmUser), '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe B: maintainers injection ----
{
  logHeader('PROBE B — maintainers list injection')
  const out = await publish('maintainers', { maintainers: [SENTINEL.maintainer] })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest.maintainers: ${JSON.stringify(m.manifest.maintainers)}`)
    const accepted = m.manifest.maintainers?.[0]?.name === SENTINEL.maintainer.name
    record('maintainers', JSON.stringify([SENTINEL.maintainer]).slice(0, 50), JSON.stringify(m.manifest.maintainers).slice(0, 50), accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN', out.res.status)
  } else {
    record('maintainers', JSON.stringify([SENTINEL.maintainer]), '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe C: _id injection (manifest level) ----
{
  logHeader('PROBE C — _id (versioned) injection')
  const out = await publish('id', { _id: SENTINEL.id })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest._id: ${m.manifest._id}`)
    const accepted = m.manifest._id === SENTINEL.id
    record('_id (version)', SENTINEL.id, m.manifest._id, accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN', out.res.status)
  } else {
    record('_id (version)', SENTINEL.id, '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe D: _npmOperationalInternal injection ----
{
  logHeader('PROBE D — _npmOperationalInternal injection')
  const out = await publish('opint', { _npmOperationalInternal: SENTINEL.opInternal })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest._npmOperationalInternal: ${JSON.stringify(m.manifest._npmOperationalInternal)}`)
    const accepted = m.manifest._npmOperationalInternal?.host === SENTINEL.opInternal.host
    record('_npmOperationalInternal', JSON.stringify(SENTINEL.opInternal).slice(0, 50), JSON.stringify(m.manifest._npmOperationalInternal).slice(0, 50), accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN', out.res.status)
  } else {
    record('_npmOperationalInternal', JSON.stringify(SENTINEL.opInternal), '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe E: _hasShrinkwrap = true when tarball has none ----
{
  logHeader('PROBE E — _hasShrinkwrap = true (tarball has none)')
  const out = await publish('shrinkwrap', { _hasShrinkwrap: true })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest._hasShrinkwrap: ${m.manifest._hasShrinkwrap}`)
    const accepted = m.manifest._hasShrinkwrap === true
    record('_hasShrinkwrap', 'true (no actual shrinkwrap)', String(m.manifest._hasShrinkwrap), accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN', out.res.status)
  } else {
    record('_hasShrinkwrap', 'true', '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe F: _nodeVersion + _npmVersion injection (publisher-set, not strictly managed) ----
{
  logHeader('PROBE F — _nodeVersion + _npmVersion injection')
  const out = await publish('versions', { _nodeVersion: SENTINEL.nodeVersion, _npmVersion: SENTINEL.npmVersion })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest._nodeVersion: ${m.manifest._nodeVersion}`)
    console.log(`  manifest._npmVersion:  ${m.manifest._npmVersion}`)
    const accepted = m.manifest._nodeVersion === SENTINEL.nodeVersion && m.manifest._npmVersion === SENTINEL.npmVersion
    record('_nodeVersion/_npmVersion', `${SENTINEL.nodeVersion} / ${SENTINEL.npmVersion}`, `${m.manifest._nodeVersion} / ${m.manifest._npmVersion}`, accepted ? 'ACCEPTED VERBATIM' : 'OVERRIDDEN', out.res.status)
  } else {
    record('_nodeVersion/_npmVersion', `${SENTINEL.nodeVersion}/${SENTINEL.npmVersion}`, '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe G: gitHead + _resolved injection ----
{
  logHeader('PROBE G — gitHead + _resolved injection')
  const out = await publish('githead', { gitHead: SENTINEL.gitHead, _resolved: SENTINEL.resolved })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest.gitHead: ${m.manifest.gitHead}`)
    console.log(`  manifest._resolved: ${m.manifest._resolved}`)
    const githeadAccepted = m.manifest.gitHead === SENTINEL.gitHead
    const resolvedAccepted = m.manifest._resolved === SENTINEL.resolved
    record('gitHead', SENTINEL.gitHead, m.manifest.gitHead || '<absent>', githeadAccepted ? 'ACCEPTED VERBATIM' : (m.manifest.gitHead ? 'OVERRIDDEN' : 'STRIPPED'), out.res.status)
    record('_resolved', SENTINEL.resolved.slice(0, 30), m.manifest._resolved || '<absent>', resolvedAccepted ? 'ACCEPTED VERBATIM' : (m.manifest._resolved ? 'OVERRIDDEN' : 'STRIPPED'), out.res.status)
  } else {
    record('gitHead/_resolved', `${SENTINEL.gitHead}/${SENTINEL.resolved}`, '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe H: dist-tags hijack — try to set 'latest' ----
{
  logHeader("PROBE H — dist-tags 'latest' hijack attempt")
  const version = `1.0.0-mfprobe-disttag-${TS}`
  const { buf, sha1, integrity } = buildTarball(version)
  const tgzName = `${PKG}-${version}.tgz`
  const body = {
    _id: PKG,
    name: PKG,
    description: 'dist-tags latest hijack probe',
    'dist-tags': { latest: version },                                    // <-- attempt to set 'latest' directly
    versions: {
      [version]: {
        name: PKG,
        version,
        license: 'MIT',
        main: 'index.js',
        _id: `${PKG}@${version}`,
        dist: { tarball: `${REGISTRY}/${PKG}/-/${tgzName}`, shasum: sha1, integrity },
      },
    },
    _attachments: {
      [tgzName]: { content_type: 'application/octet-stream', data: buf.toString('base64'), length: buf.length },
    },
  }
  const t0 = Date.now()
  const res = await fetch(`${REGISTRY}/${PKG}`, {
    method: 'PUT',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', accept: '*/*' },
    body: JSON.stringify(body),
  })
  const text = await res.text()
  console.log(`PUT HTTP ${res.status} (${Date.now() - t0} ms): ${text.slice(0, 200)}`)
  await sleep(2000)
  // Read top-level packument to inspect dist-tags
  const pr = await fetch(`${REGISTRY}/${PKG}`, { headers: { accept: 'application/json' } })
  const packument = await pr.json()
  console.log(`  dist-tags.latest currently: ${packument['dist-tags']?.latest}`)
  const isLatest = packument['dist-tags']?.latest === version
  record("dist-tags 'latest'", version, packument['dist-tags']?.latest, isLatest ? 'ACCEPTED — latest WAS HIJACKED' : 'NOT updated to probe version', res.status)
}

// ---- Summary ----
logHeader('SUMMARY')
console.log()
console.log('| Probe                          | PUT  | Verdict                                |')
console.log('|--------------------------------|------|----------------------------------------|')
for (const r of REPORT) {
  console.log(`| ${r.probe.padEnd(30)} | ${String(r.putStatus).padEnd(4)} | ${r.verdict.padEnd(38)} |`)
}
console.log()
console.log('Detail:')
for (const r of REPORT) {
  console.log(`  [${r.probe}]`)
  console.log(`    sent:   ${r.sentSummary}`)
  console.log(`    stored: ${r.storedSummary}`)
}
