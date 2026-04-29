#!/usr/bin/env node
// Cross-reference TDS-observed domains against the FBI Funnull-associated
// CNAME list (Funnull_Technology_Inc_Associated_CNAMEs.xlsx).
//
// The FBI xlsx contains 552 CNAME records of the form:
//   <customer-identifier>.<funnull-target-suffix>.
// The suffix is Funnull edge infrastructure (funnullcdn.com, fn01.vip,
// qiu199.com, etc.). The prefix is either a customer domain (rare — only
// ~6 real ones) or an opaque internal tenant id (most of the list).
//
// Exact-match between TDS-observed domains and FBI customer domains is
// expected to be zero, so this script classifies hits by several signals:
//
//   fbi_exact        — TDS hostname appears verbatim in FBI victim list.
//   fbi_subdomain    — TDS hostname is under a Funnull target suffix
//                      (e.g. ends in `.qiu199.com`, `.fn01.vip`, etc.).
//   fbi_root_shared  — TDS eTLD+1 appears in either FBI victims or targets
//                      (captures cases where a Funnull-linked root is
//                      exposed as a plain subdomain).
//   fbi_pattern      — TDS hostname follows the naming convention of an
//                      FBI Funnull target (e.g. `qiu*.com`, `dq*.com`).
//
// Outputs:
//   tds-analysis/funnull-cnames.json      parsed FBI list (structured)
//   tds-analysis/funnull-matches.csv      per-TDS-domain match detail
//   tds-packages.csv (updated)            + fbi_funnull_* columns
//   tds-versions.csv (updated)            + fbi_funnull_* columns

import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'

const ROOT = path.resolve(new URL('.', import.meta.url).pathname, '..')
const XLSX_DIR = '/tmp/funnull-xlsx'
const OUT_DIR = path.join(ROOT, 'tds-analysis')

// Funnull edge suffixes observed in the FBI list; anything after the first
// '.' that matches one of these is treated as Funnull infrastructure.
const FUNNULL_SUFFIXES = [
  'funnullcdn.com', 'funnull-cdn.com', 'funnull-accelerate.com',
  'funnull301.com', 'funnullv8.com', 'funnullv10.com', 'funnullv23.com',
  'funnullv26.com', 'funnull6.com', 'funnull.org', 'fnvip100.com',
  'funnull.vip', 'funnull01.vip', 'funnull02.vip',
  'fn01.vip', 'fn02.vip', 'fn03.vip',
  'qiu199.com', 'pt4.tv'
]

// Pattern families observed across both FBI and TDS datasets. If a TDS
// hostname matches one of these patterns, we flag fbi_pattern with the
// family name so an investigator can cluster them.
const PATTERN_FAMILIES = [
  { name: 'qiu-numeric',   re: /(?:^|[.-])qiu\d{2,5}(?:\.|$)/ },       // qiu199, qiu577, qiu994…
  { name: 'dqiu-numeric',  re: /(?:^|[.-])dqiu\d{2,5}(?:\.|$)/ },      // dqiu66…
  { name: 'dq-numeric',    re: /(?:^|[.-])dq\d{3,6}(?:\.|$)/ },        // dq87770…dq87776
  { name: 'funnull-brand', re: /funnull/ },
  { name: 'pt-tv',         re: /(?:^|\.)pt\d*\.tv$/ }
]

async function parseSharedStrings () {
  const xml = await readFile(path.join(XLSX_DIR, 'xl/sharedStrings.xml'), 'utf8')
  const out = []
  const re = /<t[^>]*>([^<]*)<\/t>/g
  let m
  while ((m = re.exec(xml))) out.push(m[1])
  return out
}

function splitCname (cname) {
  const c = cname.replace(/\.$/, '').toLowerCase()
  for (const suf of FUNNULL_SUFFIXES) {
    const needle = `.${suf}`
    if (c.endsWith(needle)) return { victim: c.slice(0, -needle.length), target: suf, raw: c }
    if (c === suf) return { victim: '', target: suf, raw: c }
  }
  const parts = c.split('.')
  return { victim: parts.slice(0, -2).join('.'), target: parts.slice(-2).join('.'), raw: c, unknownTarget: true }
}

function etld1 (host) {
  // Rough eTLD+1: last two labels (doesn't handle multi-part TLDs perfectly;
  // fine for our purposes since `.com.cn` etc. are already included in the
  // compound-target suffix list below as needed).
  const p = host.split('.')
  return p.slice(-2).join('.')
}

function classifyTdsDomain (tdsHost, victims, targets, victimsEtld1, targetsEtld1) {
  const host = tdsHost.toLowerCase()
  const etld = etld1(host)
  const exact = victims.has(host)
  let subdomainTarget = null
  for (const t of targets) {
    if (host.endsWith(`.${t}`)) { subdomainTarget = t; break }
  }
  const rootShared = targetsEtld1.has(etld) || victimsEtld1.has(etld)
  const patterns = PATTERN_FAMILIES.filter(p => p.re.test(host)).map(p => p.name)
  return { host, exact, subdomainTarget, rootShared, rootEtld1: etld, patterns }
}

function parseCsvLine (line) {
  const cells = []
  let cur = ''
  let inQ = false
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    if (inQ) {
      if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++ }
      else if (ch === '"') inQ = false
      else cur += ch
    } else {
      if (ch === '"') inQ = true
      else if (ch === ',') { cells.push(cur); cur = '' }
      else cur += ch
    }
  }
  cells.push(cur)
  return cells
}

function csvCell (v) {
  if (v === null || v === undefined) return ''
  const s = String(v)
  if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`
  return s
}

function stripScheme (d) {
  return d.replace(/^https?:\/\//, '').replace(/\/$/, '').toLowerCase()
}

async function main () {
  const strings = await parseSharedStrings()
  const cnames = strings.filter(s => s !== 'CNAMEs' && /\./.test(s))
  const split = cnames.map(splitCname)

  const victims = new Set(split.map(s => s.victim).filter(Boolean))
  const targets = new Set(split.map(s => s.target))
  const victimsEtld1 = new Set([...victims].map(etld1))
  const targetsEtld1 = new Set([...targets].map(etld1))

  console.error(`FBI list: ${cnames.length} CNAMEs; ${victims.size} victim prefixes; ${targets.size} Funnull targets.`)

  await writeFile(path.join(OUT_DIR, 'funnull-cnames.json'), JSON.stringify({
    generatedAt: new Date().toISOString(),
    source: 'Funnull_Technology_Inc_Associated_CNAMEs.xlsx (FBI advisory, May 29 2025)',
    totalCnames: cnames.length,
    uniqueVictims: victims.size,
    uniqueTargets: targets.size,
    targetCounts: Object.fromEntries([...targets].map(t => [t, split.filter(s => s.target === t).length])),
    realLookingVictims: [...victims].filter(v => /^[a-z0-9._-]+\.[a-z]{2,}$/i.test(v)),
    entries: split
  }, null, 2))

  const pkgCsvRaw = (await readFile(path.join(OUT_DIR, 'tds-packages.csv'), 'utf8')).split('\n').filter(Boolean)
  const verCsvRaw = (await readFile(path.join(OUT_DIR, 'tds-versions.csv'), 'utf8')).split('\n').filter(Boolean)
  const pkgHeader = parseCsvLine(pkgCsvRaw[0])
  const verHeader = parseCsvLine(verCsvRaw[0])

  // If previous run already added fbi_* columns, strip them before re-adding.
  function stripFbiCols (header, lines) {
    const keepIdx = header.map((h, i) => h.startsWith('fbi_funnull') ? -1 : i).filter(i => i !== -1)
    const newHeader = keepIdx.map(i => header[i])
    const newLines = lines.map(l => {
      const cells = parseCsvLine(l)
      return keepIdx.map(i => cells[i])
    })
    return { header: newHeader, rows: newLines }
  }
  const pkg = stripFbiCols(pkgHeader, pkgCsvRaw.slice(1))
  const ver = stripFbiCols(verHeader, verCsvRaw.slice(1))
  const pkgDomIdx = pkg.header.indexOf('domains')
  const verDomIdx = ver.header.indexOf('domains')

  // Collect unique TDS hosts across both CSVs.
  const tdsHosts = new Set()
  for (const row of pkg.rows) {
    (row[pkgDomIdx] || '').split(';').filter(Boolean).map(stripScheme).forEach(h => tdsHosts.add(h))
  }
  for (const row of ver.rows) {
    (row[verDomIdx] || '').split(';').filter(Boolean).map(stripScheme).forEach(h => tdsHosts.add(h))
  }

  // Classify each unique TDS host.
  const classifications = new Map()
  for (const h of tdsHosts) {
    classifications.set(h, classifyTdsDomain(h, victims, targets, victimsEtld1, targetsEtld1))
  }

  // Tally.
  const counts = { exact: 0, subdomain: 0, rootShared: 0, pattern: 0, any: 0 }
  for (const c of classifications.values()) {
    const any = c.exact || c.subdomainTarget || c.rootShared || c.patterns.length > 0
    if (c.exact) counts.exact++
    if (c.subdomainTarget) counts.subdomain++
    if (c.rootShared) counts.rootShared++
    if (c.patterns.length) counts.pattern++
    if (any) counts.any++
  }
  console.error(`TDS hosts: ${tdsHosts.size}. Matches: exact=${counts.exact} subdomain=${counts.subdomain} root_shared=${counts.rootShared} pattern=${counts.pattern} any=${counts.any}`)

  // Per-domain CSV.
  const xref = ['tds_domain,fbi_exact,fbi_subdomain_target,fbi_root_shared,fbi_root,fbi_pattern_families']
  for (const c of [...classifications.values()].sort((a, b) => a.host.localeCompare(b.host))) {
    xref.push([
      csvCell(c.host), csvCell(c.exact), csvCell(c.subdomainTarget || ''),
      csvCell(c.rootShared), csvCell(c.rootEtld1), csvCell(c.patterns.join(';'))
    ].join(','))
  }
  await writeFile(path.join(OUT_DIR, 'funnull-matches.csv'), xref.join('\n') + '\n')

  // Helper: summarise a row's domain list into new fbi_* columns.
  function rowSummary (domsRaw) {
    const hosts = (domsRaw || '').split(';').filter(Boolean).map(stripScheme)
    let anyCount = 0
    const exactHits = []
    const subdomainHits = []
    const patternHits = new Set()
    let rootSharedCount = 0
    for (const h of hosts) {
      const c = classifications.get(h)
      if (!c) continue
      const hit = c.exact || c.subdomainTarget || c.rootShared || c.patterns.length > 0
      if (hit) anyCount++
      if (c.exact) exactHits.push(h)
      if (c.subdomainTarget) subdomainHits.push(`${h}->${c.subdomainTarget}`)
      if (c.rootShared) rootSharedCount++
      c.patterns.forEach(p => patternHits.add(p))
    }
    return {
      any_count: anyCount,
      exact_hits: exactHits.join(';'),
      subdomain_hits: subdomainHits.join(';'),
      root_shared_count: rootSharedCount,
      pattern_families: [...patternHits].join(';')
    }
  }

  function writeAugmented (outPath, header, rows, domIdx) {
    const newHeader = [...header, 'fbi_funnull_any_count', 'fbi_funnull_exact', 'fbi_funnull_subdomain_of_target', 'fbi_funnull_root_shared_count', 'fbi_funnull_pattern_families']
    const out = [newHeader.map(csvCell).join(',')]
    for (const r of rows) {
      const s = rowSummary(r[domIdx])
      out.push([...r, s.any_count, s.exact_hits, s.subdomain_hits, s.root_shared_count, s.pattern_families].map(csvCell).join(','))
    }
    return writeFile(outPath, out.join('\n') + '\n')
  }

  await writeAugmented(path.join(OUT_DIR, 'tds-packages.csv'), pkg.header, pkg.rows, pkgDomIdx)
  await writeAugmented(path.join(OUT_DIR, 'tds-versions.csv'), ver.header, ver.rows, verDomIdx)

  console.error(`Wrote:\n  ${path.relative(ROOT, path.join(OUT_DIR, 'funnull-cnames.json'))}\n  ${path.relative(ROOT, path.join(OUT_DIR, 'funnull-matches.csv'))}\n  tds-packages.csv / tds-versions.csv (+fbi_funnull_* columns)`)
}

main().catch(e => { console.error(e); process.exit(1) })
