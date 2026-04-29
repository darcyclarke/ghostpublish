#!/usr/bin/env node
// Enumerate every package under the @yuming2022 and @hd-team scopes, download
// and keep each tarball, recursively base64-decode the payload inside
// index.js, and emit a CSV describing the current state.
//
// Output layout (under ./tds-analysis):
//   tarballs/<scope>/<name>/<version>.tgz
//   extracted/<scope>/<name>/<version>/...
//   decoded/<scope>/<name>/<version>.json    (fully-decoded payload)
//   metadata/<scope>/<name>/packument.json   (full registry metadata)
//   metadata/<scope>/<name>/downloads.json   (download stats)
//   tds-packages.csv                         (one row per package)
//   tds-versions.csv                         (one row per version examined)
//
// Usage:
//   node scripts/tds-enumerate.mjs [--versions-per-package N]
// Default is 20 most-recent versions per package.

import { mkdir, writeFile, readFile, stat } from 'node:fs/promises'
import { spawn } from 'node:child_process'
import { createWriteStream } from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(new URL('.', import.meta.url).pathname, '..')
const OUT = path.join(ROOT, 'tds-analysis')
const SCOPES = ['yuming2022', 'hd-team']
const KNOWN_CDNS = ['funnull', 'aliyun', 'hw', 'huawei', 'yundun']

const args = process.argv.slice(2)
const vppIdx = args.indexOf('--versions-per-package')
const VERSIONS_PER_PACKAGE = vppIdx >= 0 ? parseInt(args[vppIdx + 1], 10) : 20

const REGISTRY = 'https://registry.npmjs.org'
const DOWNLOADS = 'https://api.npmjs.org/downloads'

async function ensureDir (p) { await mkdir(p, { recursive: true }) }

async function fetchJson (url) {
  const res = await fetch(url, { headers: { accept: 'application/json' } })
  if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${url}`)
  return res.json()
}

async function fetchBuf (url) {
  const res = await fetch(url)
  if (!res.ok) throw new Error(`${res.status} ${res.statusText} for ${url}`)
  return Buffer.from(await res.arrayBuffer())
}

async function listScopePackages (scope) {
  // npm search is paginated; bump size once to cover the known max (43).
  const data = await fetchJson(`${REGISTRY}/-/v1/search?text=maintainer:${scope}&size=250`)
  return data.objects.map(o => o.package.name).filter(n => n.startsWith(`@${scope}/`))
}

function runTar (args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn('tar', args, { cwd, stdio: ['ignore', 'pipe', 'pipe'] })
    let err = ''
    child.stderr.on('data', d => { err += d })
    child.on('close', code => code === 0 ? resolve() : reject(new Error(`tar ${args.join(' ')} exited ${code}: ${err}`)))
  })
}

function looksLikeBase64 (s) {
  if (typeof s !== 'string') return false
  const t = s.trim()
  if (t.length < 4) return false
  if (t.length % 4 !== 0) return false
  return /^[A-Za-z0-9+/]+={0,2}$/.test(t)
}

// Recursive decode: take raw file bytes, base64-decode until the result
// stops being base64 OR until it becomes valid JSON. Then walk the JSON and
// decode any string child that itself looks like base64.
function recursiveDecode (raw) {
  let current = raw.trim()
  const steps = []
  for (let i = 0; i < 6; i++) {
    if (!looksLikeBase64(current)) break
    try {
      const decoded = Buffer.from(current, 'base64').toString('utf8')
      // Reject junk decodes (mostly non-printable)
      const printable = decoded.replace(/[\x20-\x7e\s一-鿿]/g, '').length
      if (printable > decoded.length * 0.1) break
      steps.push({ layer: i + 1, len: decoded.length })
      current = decoded.trim()
    } catch {
      break
    }
  }
  let parsed = null
  try { parsed = JSON.parse(current) } catch {}
  if (parsed && typeof parsed === 'object') {
    decodeJsonStrings(parsed)
  }
  return { finalText: current, json: parsed, layers: steps.length }
}

function decodeJsonStrings (node) {
  if (Array.isArray(node)) { node.forEach(decodeJsonStrings); return }
  if (!node || typeof node !== 'object') return
  for (const [k, v] of Object.entries(node)) {
    if (typeof v === 'string' && looksLikeBase64(v) && v.length < 64) {
      try {
        const decoded = Buffer.from(v, 'base64').toString('utf8')
        if (/^[\x20-\x7e]+$/.test(decoded)) {
          node[`${k}_decoded`] = decoded
        }
      } catch {}
    } else {
      decodeJsonStrings(v)
    }
  }
}

function extractConfig (json) {
  if (!json) return null
  const entries = Array.isArray(json.data) ? json.data : (Array.isArray(json) ? json : [])
  const cdns = new Set()
  const domains = new Set()
  const tokens = new Set()
  const signTypes = new Set()
  const platforms = new Set()
  let openTrue = 0, openFalse = 0
  let totalWeight = 0
  for (const e of entries) {
    if (!e || typeof e !== 'object') continue
    const cdnDecoded = e.cdn_decoded || (typeof e.cdn === 'string' ? (() => {
      try { return Buffer.from(e.cdn, 'base64').toString('utf8') } catch { return e.cdn }
    })() : null)
    if (cdnDecoded) cdns.add(cdnDecoded.toLowerCase())
    if (e.domain) domains.add(String(e.domain))
    if (e.token) tokens.add(String(e.token))
    if (e.signType) signTypes.add(String(e.signType))
    if (e.platform) platforms.add(String(e.platform))
    if (e.clientType) platforms.add(String(e.clientType))
    if (e.openFlag === true) openTrue++
    else if (e.openFlag === false) openFalse++
    if (typeof e.weight === 'number') totalWeight += e.weight
  }
  return {
    cdns: [...cdns],
    domains: [...domains],
    tokens: [...tokens],
    signTypes: [...signTypes],
    platforms: [...platforms],
    openTrue, openFalse, totalWeight,
    msg: json.msg || '',
    code: json.code,
    entryCount: entries.length
  }
}

function csvCell (v) {
  if (v === null || v === undefined) return ''
  const s = Array.isArray(v) ? v.join(';') : String(v)
  if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`
  return s
}

function csvRow (vals) { return vals.map(csvCell).join(',') + '\n' }

async function processPackage (scope, name, state) {
  const bare = name.replace(`@${scope}/`, '')
  const pkgMetaDir = path.join(OUT, 'metadata', scope, bare)
  const pkgTarDir = path.join(OUT, 'tarballs', scope, bare)
  const pkgExtDir = path.join(OUT, 'extracted', scope, bare)
  const pkgDecDir = path.join(OUT, 'decoded', scope, bare)
  await Promise.all([pkgMetaDir, pkgTarDir, pkgExtDir, pkgDecDir].map(ensureDir))

  const packument = await fetchJson(`${REGISTRY}/${encodeURIComponent(name)}`)
  await writeFile(path.join(pkgMetaDir, 'packument.json'), JSON.stringify(packument, null, 2))

  let weeklyDownloads = 0
  try {
    const dl = await fetchJson(`${DOWNLOADS}/point/last-week/${encodeURIComponent(name)}`)
    weeklyDownloads = dl.downloads ?? 0
    await writeFile(path.join(pkgMetaDir, 'downloads-last-week.json'), JSON.stringify(dl, null, 2))
  } catch (e) { /* may 404 for tiny packages */ }
  let monthlyDownloads = 0
  try {
    const dl = await fetchJson(`${DOWNLOADS}/point/last-month/${encodeURIComponent(name)}`)
    monthlyDownloads = dl.downloads ?? 0
    await writeFile(path.join(pkgMetaDir, 'downloads-last-month.json'), JSON.stringify(dl, null, 2))
  } catch (e) {}

  const allVersions = Object.keys(packument.versions || {})
  const time = packument.time || {}
  const sorted = allVersions
    .map(v => ({ version: v, time: time[v] || null }))
    .sort((a, b) => (b.time || '').localeCompare(a.time || ''))
  const recentVersions = sorted.slice(0, VERSIONS_PER_PACKAGE)
  const firstPublish = sorted.length ? sorted[sorted.length - 1].time : null
  const lastPublish = sorted.length ? sorted[0].time : null
  const latestVersion = sorted.length ? sorted[0].version : null

  const versionRows = []
  let latestConfig = null
  let latestDecoded = null

  for (const { version, time: publishTime } of recentVersions) {
    const versionMeta = packument.versions[version]
    if (!versionMeta) continue
    const tarballUrl = versionMeta.dist?.tarball
    if (!tarballUrl) continue
    const tgzPath = path.join(pkgTarDir, `${version}.tgz`)
    const versionExtDir = path.join(pkgExtDir, version)
    const decodedPath = path.join(pkgDecDir, `${version}.json`)

    let tgzBuf
    try {
      tgzBuf = await fetchBuf(tarballUrl)
      await writeFile(tgzPath, tgzBuf)
    } catch (e) {
      versionRows.push({ scope, name, version, error: `download_failed: ${e.message}`, publishTime })
      continue
    }

    await ensureDir(versionExtDir)
    try {
      await runTar(['-xzf', tgzPath, '--strip-components=1', '-C', versionExtDir], pkgExtDir)
    } catch (e) {
      versionRows.push({ scope, name, version, error: `extract_failed: ${e.message}`, publishTime, tarballSize: tgzBuf.length })
      continue
    }

    // Inventory the extracted package
    const files = await listFilesRecursive(versionExtDir)
    let indexJs = null
    try { indexJs = await readFile(path.join(versionExtDir, 'index.js'), 'utf8') } catch {}
    let packageJson = null
    try { packageJson = JSON.parse(await readFile(path.join(versionExtDir, 'package.json'), 'utf8')) } catch {}

    let decoded = null
    let config = null
    if (indexJs) {
      decoded = recursiveDecode(indexJs)
      if (decoded.json) {
        config = extractConfig(decoded.json)
      }
      await writeFile(decodedPath, JSON.stringify({
        package: name, version, publishTime,
        layers: decoded.layers,
        rawText: decoded.finalText.slice(0, 4096),
        json: decoded.json,
        config
      }, null, 2))
    }

    versionRows.push({
      scope, name, version, publishTime,
      tarballSize: tgzBuf.length,
      fileCount: files.length,
      hasIndexJs: !!indexJs,
      indexJsSize: indexJs?.length || 0,
      packageJsonFields: packageJson ? Object.keys(packageJson).length : 0,
      decodedOk: !!decoded?.json,
      decodeLayers: decoded?.layers || 0,
      config
    })
    if (version === latestVersion) {
      latestConfig = config
      latestDecoded = decoded
    }
  }

  const rowSummary = {
    scope, name, bare,
    totalVersions: allVersions.length,
    versionsExamined: versionRows.length,
    firstPublish, lastPublish, latestVersion,
    weeklyDownloads, monthlyDownloads,
    latestConfig,
    latestDecodeLayers: latestDecoded?.layers || 0
  }
  state.packageRows.push(rowSummary)
  state.versionRows.push(...versionRows)
  state.processed++
  process.stderr.write(`[${state.processed}/${state.total}] ${name} — ${versionRows.length} versions, ${weeklyDownloads} dl/wk\n`)
}

async function listFilesRecursive (dir) {
  const out = []
  async function walk (d) {
    const { readdir } = await import('node:fs/promises')
    const entries = await readdir(d, { withFileTypes: true })
    for (const e of entries) {
      const p = path.join(d, e.name)
      if (e.isDirectory()) await walk(p)
      else out.push(path.relative(dir, p))
    }
  }
  try { await walk(dir) } catch {}
  return out
}

async function main () {
  await ensureDir(OUT)
  const packages = []
  for (const scope of SCOPES) {
    const pkgs = await listScopePackages(scope)
    pkgs.forEach(p => packages.push({ scope, name: p }))
  }
  process.stderr.write(`Enumerating ${packages.length} packages across ${SCOPES.length} scopes (up to ${VERSIONS_PER_PACKAGE} versions each)\n`)

  const state = { packageRows: [], versionRows: [], processed: 0, total: packages.length }

  // Serial to be gentle on the registry; packages are small.
  for (const { scope, name } of packages) {
    try { await processPackage(scope, name, state) }
    catch (e) { process.stderr.write(`ERROR ${name}: ${e.message}\n`) }
  }

  // Package-level CSV
  const pkgHeader = [
    'scope', 'package', 'total_versions', 'versions_examined',
    'first_publish', 'last_publish', 'days_since_last_publish',
    'latest_version', 'weekly_downloads', 'monthly_downloads',
    'decoded_ok', 'decode_layers', 'entry_count',
    'cdn_funnull', 'cdn_aliyun', 'cdn_hw', 'cdn_huawei', 'cdn_yundun', 'cdn_other',
    'cdns', 'domains', 'tokens', 'sign_types', 'platforms',
    'open_flag_true', 'open_flag_false', 'total_weight', 'msg_decoded'
  ]
  const pkgLines = [pkgHeader.join(',')]
  for (const r of state.packageRows) {
    const c = r.latestConfig || {}
    const cdns = c.cdns || []
    const otherCdns = cdns.filter(x => !KNOWN_CDNS.includes(x))
    const now = new Date()
    const days = r.lastPublish ? Math.floor((now - new Date(r.lastPublish)) / 86400000) : null
    pkgLines.push(csvRow([
      r.scope, r.name, r.totalVersions, r.versionsExamined,
      r.firstPublish || '', r.lastPublish || '', days ?? '',
      r.latestVersion || '', r.weeklyDownloads, r.monthlyDownloads,
      !!r.latestConfig, r.latestDecodeLayers || 0, c.entryCount ?? '',
      cdns.includes('funnull'), cdns.includes('aliyun'),
      cdns.includes('hw'), cdns.includes('huawei'), cdns.includes('yundun'),
      otherCdns,
      cdns, c.domains || [], c.tokens || [], c.signTypes || [], c.platforms || [],
      c.openTrue ?? '', c.openFalse ?? '', c.totalWeight ?? '', c.msg || ''
    ]).replace(/\n$/, ''))
  }
  await writeFile(path.join(OUT, 'tds-packages.csv'), pkgLines.join('\n') + '\n')

  // Version-level CSV
  const verHeader = [
    'scope', 'package', 'version', 'publish_time', 'tarball_bytes',
    'file_count', 'has_index_js', 'index_js_size', 'package_json_fields',
    'decoded_ok', 'decode_layers', 'entry_count',
    'cdns', 'domains', 'tokens', 'sign_types',
    'open_flag_true', 'open_flag_false', 'error'
  ]
  const verLines = [verHeader.join(',')]
  for (const v of state.versionRows) {
    const c = v.config || {}
    verLines.push(csvRow([
      v.scope, v.name, v.version, v.publishTime || '', v.tarballSize || '',
      v.fileCount || '', !!v.hasIndexJs, v.indexJsSize || '', v.packageJsonFields || '',
      !!v.decodedOk, v.decodeLayers || 0, c.entryCount ?? '',
      c.cdns || [], c.domains || [], c.tokens || [], c.signTypes || [],
      c.openTrue ?? '', c.openFalse ?? '', v.error || ''
    ]).replace(/\n$/, ''))
  }
  await writeFile(path.join(OUT, 'tds-versions.csv'), verLines.join('\n') + '\n')

  // Summary JSON (for the markdown write-up)
  await writeFile(path.join(OUT, 'summary.json'), JSON.stringify({
    generatedAt: new Date().toISOString(),
    scopes: SCOPES,
    versionsPerPackage: VERSIONS_PER_PACKAGE,
    packageCount: state.packageRows.length,
    versionRowCount: state.versionRows.length,
    perPackage: state.packageRows.map(r => ({
      name: r.name,
      totalVersions: r.totalVersions,
      lastPublish: r.lastPublish,
      weeklyDownloads: r.weeklyDownloads,
      monthlyDownloads: r.monthlyDownloads,
      cdns: r.latestConfig?.cdns || [],
      domains: r.latestConfig?.domains || [],
      tokens: r.latestConfig?.tokens || []
    }))
  }, null, 2))

  process.stderr.write(`\nDone. ${state.packageRows.length} packages, ${state.versionRows.length} versions.\n`)
  process.stderr.write(`CSV: ${path.relative(ROOT, path.join(OUT, 'tds-packages.csv'))}\n`)
  process.stderr.write(`     ${path.relative(ROOT, path.join(OUT, 'tds-versions.csv'))}\n`)
}

main().catch(e => { console.error(e); process.exit(1) })
