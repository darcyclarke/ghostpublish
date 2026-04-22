#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: vlr test:integrity <pkg>@<version>"
  echo "  e.g. vlr test:integrity next@15.1.1-canary.0"
  exit 1
fi

INPUT="$1"
PKG="${INPUT%@*}"
VERSION="${INPUT##*@}"

if [ -z "$PKG" ] || [ -z "$VERSION" ] || [ "$PKG" = "$VERSION" ]; then
  echo "Error: must specify both package and version as <pkg>@<version>"
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== Integrity check: ${PKG}@${VERSION} ==="
echo ""

# --- Manifest ---
echo "[1/5] Fetching manifest..."
MANIFEST=$(curl -sf "https://registry.npmjs.org/${PKG}/${VERSION}" 2>/dev/null) || {
  echo "  FAIL: could not fetch manifest for ${PKG}@${VERSION}"
  echo "  (does this version exist?)"
  exit 1
}

M_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // empty')
M_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // empty')
TARBALL_URL=$(echo "$MANIFEST" | jq -r '.dist.tarball // empty')

if [ -z "$TARBALL_URL" ]; then
  echo "  FAIL: no tarball URL in manifest"
  exit 1
fi

echo "  shasum:    ${M_SHASUM:-"(none)"}"
echo "  integrity: ${M_INTEGRITY:-"(none)"}"
echo "  tarball:   ${TARBALL_URL}"
echo ""

# --- Download ---
echo "[2/5] Downloading tarball..."
TARBALL="${TMPDIR}/pkg.tgz"
HTTP_CODE=$(curl -sL -o "$TARBALL" -w '%{http_code}' "$TARBALL_URL")

if [ "$HTTP_CODE" != "200" ]; then
  echo "  FAIL: tarball download returned HTTP ${HTTP_CODE}"
  exit 1
fi

SIZE=$(wc -c < "$TARBALL" | tr -d ' ')
SIZE_HUMAN=$(ls -lh "$TARBALL" | awk '{print $5}')
echo "  size: ${SIZE_HUMAN} (${SIZE} bytes)"

if [ "$SIZE" -lt 100 ]; then
  echo "  FAIL: tarball suspiciously small (${SIZE} bytes)"
  exit 1
fi
echo ""

# --- Hash verification ---
echo "[3/5] Verifying hashes..."

ACTUAL_SHA1=$(shasum -a 1 "$TARBALL" | cut -d' ' -f1)

SHA1_OK=false
if [ -n "$M_SHASUM" ]; then
  if [ "$M_SHASUM" = "$ACTUAL_SHA1" ]; then
    echo "  SHA-1:   MATCH ($ACTUAL_SHA1)"
    SHA1_OK=true
  else
    echo "  SHA-1:   MISMATCH"
    echo "    manifest: $M_SHASUM"
    echo "    actual:   $ACTUAL_SHA1"
  fi
else
  echo "  SHA-1:   (no shasum in manifest, skipped)"
  SHA1_OK=true
fi

SHA512_OK=false
if [ -n "$M_INTEGRITY" ]; then
  ALGO=$(echo "$M_INTEGRITY" | cut -d- -f1)
  M_B64=$(echo "$M_INTEGRITY" | cut -d- -f2-)

  if [ "$ALGO" = "sha512" ]; then
    ACTUAL_SHA512_HEX=$(shasum -a 512 "$TARBALL" | cut -d' ' -f1)
    ACTUAL_B64=$(echo "$ACTUAL_SHA512_HEX" | xxd -r -p | base64 | tr -d '\n')

    if [ "$M_B64" = "$ACTUAL_B64" ]; then
      echo "  SHA-512: MATCH"
      SHA512_OK=true
    else
      echo "  SHA-512: MISMATCH"
      echo "    manifest: ${M_B64:0:48}..."
      echo "    actual:   ${ACTUAL_B64:0:48}..."
    fi
  elif [ "$ALGO" = "sha256" ]; then
    ACTUAL_SHA256_HEX=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
    ACTUAL_B64=$(echo "$ACTUAL_SHA256_HEX" | xxd -r -p | base64 | tr -d '\n')

    if [ "$M_B64" = "$ACTUAL_B64" ]; then
      echo "  SHA-256: MATCH"
      SHA512_OK=true
    else
      echo "  SHA-256: MISMATCH"
      echo "    manifest: ${M_B64:0:48}..."
      echo "    actual:   ${ACTUAL_B64:0:48}..."
    fi
  else
    echo "  integrity: unknown algorithm '${ALGO}', skipped"
    SHA512_OK=true
  fi
else
  echo "  integrity: (no integrity field in manifest, skipped)"
  SHA512_OK=true
fi
echo ""

# --- Tarball structure ---
echo "[4/5] Validating tarball structure..."

EXTRACT="${TMPDIR}/extract"
mkdir -p "$EXTRACT"

if ! tar xzf "$TARBALL" -C "$EXTRACT" 2>/dev/null; then
  echo "  FAIL: tarball is malformed (tar extraction failed)"
  exit 1
fi
echo "  extraction: OK"

if [ ! -d "${EXTRACT}/package" ]; then
  TOP_DIRS=$(ls "$EXTRACT")
  echo "  FAIL: no /package directory inside tarball"
  echo "    found: ${TOP_DIRS}"
  exit 1
fi
echo "  /package:   present"

PKG_JSON="${EXTRACT}/package/package.json"
if [ ! -f "$PKG_JSON" ]; then
  echo "  FAIL: no package.json inside /package"
  exit 1
fi
echo "  package.json: present"

INNER_NAME=$(jq -r '.name // empty' "$PKG_JSON")
INNER_VERSION=$(jq -r '.version // empty' "$PKG_JSON")

NAME_OK=true
if [ -n "$INNER_NAME" ] && [ "$INNER_NAME" != "$PKG" ]; then
  echo "  WARNING: package.json name mismatch (expected '${PKG}', got '${INNER_NAME}')"
  NAME_OK=false
fi

VER_OK=true
if [ -n "$INNER_VERSION" ] && [ "$INNER_VERSION" != "$VERSION" ]; then
  echo "  WARNING: package.json version mismatch (expected '${VERSION}', got '${INNER_VERSION}')"
  VER_OK=false
fi

FILE_COUNT=$(find "${EXTRACT}/package" -type f | wc -l | tr -d ' ')
echo "  files:      ${FILE_COUNT}"
echo ""

# --- Attestations ---
echo "[5/5] Checking attestations..."
ATTEST_JSON=$(curl -sf "https://registry.npmjs.org/-/npm/v1/attestations/${PKG}@${VERSION}" 2>/dev/null || echo '{"attestations":[]}')
ATTEST_COUNT=$(echo "$ATTEST_JSON" | jq '.attestations | length')

if [ "$ATTEST_COUNT" -eq 0 ]; then
  echo "  attestations: 0 (no provenance)"
else
  UNIQUE_HASHES=$(echo "$ATTEST_JSON" | python3 -c "
import json, sys, base64
data = json.load(sys.stdin)
hashes = set()
for a in data.get('attestations', []):
  payload = a.get('bundle', {}).get('dsseEnvelope', {}).get('payload', '')
  if payload:
    try:
      pred = json.loads(base64.b64decode(payload))
      for s in pred.get('subject', []):
        for digest in s.get('digest', {}).values():
          hashes.add(digest)
    except: pass
print(len(hashes))
" 2>/dev/null || echo "?")

  echo "  attestations: ${ATTEST_COUNT}"
  echo "  unique hashes: ${UNIQUE_HASHES}"
  if [ "$UNIQUE_HASHES" != "?" ] && [ "$UNIQUE_HASHES" -gt 1 ]; then
    echo "  WARNING: multiple distinct hashes — possible dual-publish"
  fi
fi
echo ""

# --- Verdict ---
echo "==========================================="
if $SHA1_OK && $SHA512_OK; then
  echo "RESULT: PASS — integrity consistent"
  if [ "$ATTEST_COUNT" -gt 0 ] && [ "$UNIQUE_HASHES" != "?" ] && [ "$UNIQUE_HASHES" -gt 1 ]; then
    echo "  (but attestation anomaly detected)"
  fi
else
  echo "RESULT: FAIL — integrity MISMATCH"
  echo "  The registry manifest hashes do not match the tarball served by the CDN."
  echo "  This version may have been affected by a publish race condition."
fi
echo "==========================================="
