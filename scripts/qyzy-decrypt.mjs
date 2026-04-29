#!/usr/bin/env node
// AES-128-CBC decrypter for QYZY-template encrypted-domain blobs.
// Key + IV are hardcoded in QYZYDomain.m (Sport1 / dq forks):
//   PSW_AES_KEY      = "8930ba380e7fdadf"
//   AES_IV_PARAMETER = "510cf0fcbdc4d20f"

import crypto from 'node:crypto'

const KEY = Buffer.from('8930ba380e7fdadf', 'utf8')
const IV  = Buffer.from('510cf0fcbdc4d20f', 'utf8')

export function decrypt(b64) {
  const ct = Buffer.from(b64, 'base64')
  const dec = crypto.createDecipheriv('aes-128-cbc', KEY, IV)
  dec.setAutoPadding(true)
  return Buffer.concat([dec.update(ct), dec.final()]).toString('utf8')
}

export function encrypt(plaintext) {
  const enc = crypto.createCipheriv('aes-128-cbc', KEY, IV)
  enc.setAutoPadding(true)
  return Buffer.concat([enc.update(plaintext, 'utf8'), enc.final()]).toString('base64')
}

// Run as CLI: pass blobs on argv, or pipe \n-separated blobs on stdin.
async function main() {
  const blobs = process.argv.slice(2)
  if (blobs.length) {
    for (const b of blobs) print(b)
    return
  }
  const stdinBuf = await new Promise((resolve) => {
    const chunks = []
    process.stdin.on('data', (c) => chunks.push(c))
    process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
  })
  for (const line of stdinBuf.split('\n')) {
    const b = line.trim()
    if (b) print(b)
  }
}

function print(b) {
  try {
    console.log(`${b}\t${decrypt(b)}`)
  } catch (err) {
    console.log(`${b}\tDECRYPT_FAIL: ${err.message}`)
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main()
