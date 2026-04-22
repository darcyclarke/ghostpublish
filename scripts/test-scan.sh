#!/bin/bash
set -euo pipefail

CSV="${1:-integrity_errors_distinct.csv}"
OUTDIR="scan"
CONCURRENCY="${2:-6}"

if [ ! -f "$CSV" ]; then
  echo "Error: CSV file not found: $CSV"
  exit 1
fi

mkdir -p "$OUTDIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS="${OUTDIR}/scan_${TIMESTAMP}.csv"
LOG="${OUTDIR}/scan_${TIMESTAMP}.log"

echo "pkg,version,manifest_exists,tarball_downloads,sha1_match,sha512_match,tarball_extracts,has_package_dir,has_package_json,name_match,version_match,file_count,tarball_size,attestation_count,unique_hashes,verdict" > "$RESULTS"

TOTAL=$(tail -n +2 "$CSV" | grep -c '.' || echo 0)
echo "=== Integrity Scan ==="
echo "Input:       $CSV ($TOTAL versions)"
echo "Output:      $RESULTS"
echo "Log:         $LOG"
echo "Concurrency: $CONCURRENCY"
echo ""

check_pkg() {
  local PKG="$1"
  local VERSION="$2"
  local IDX="$3"
  local TOTAL="$4"
  local RESULTS="$5"
  local LOG="$6"

  local TMPDIR
  TMPDIR=$(mktemp -d)

  local manifest_exists="false"
  local tarball_downloads="false"
  local sha1_match="n/a"
  local sha512_match="n/a"
  local tarball_extracts="false"
  local has_package_dir="false"
  local has_package_json="false"
  local name_match="n/a"
  local version_match="n/a"
  local file_count="0"
  local tarball_size="0"
  local attestation_count="0"
  local unique_hashes="0"
  local verdict="error"

  # 1. Fetch manifest
  local MANIFEST
  MANIFEST=$(curl -sf "https://registry.npmjs.org/${PKG}/${VERSION}" 2>/dev/null) || {
    echo "${IDX}/${TOTAL} SKIP ${PKG}@${VERSION} — manifest not found" >> "$LOG"
    echo "\"${PKG}\",\"${VERSION}\",${manifest_exists},${tarball_downloads},${sha1_match},${sha512_match},${tarball_extracts},${has_package_dir},${has_package_json},${name_match},${version_match},${file_count},${tarball_size},${attestation_count},${unique_hashes},${verdict}" >> "$RESULTS"
    rm -rf "$TMPDIR"
    return
  }
  manifest_exists="true"

  local M_INTEGRITY M_SHASUM TARBALL_URL
  M_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // ""')
  M_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // ""')
  TARBALL_URL=$(echo "$MANIFEST" | jq -r '.dist.tarball // ""')

  if [ -z "$TARBALL_URL" ]; then
    echo "${IDX}/${TOTAL} SKIP ${PKG}@${VERSION} — no tarball URL" >> "$LOG"
    echo "\"${PKG}\",\"${VERSION}\",${manifest_exists},${tarball_downloads},${sha1_match},${sha512_match},${tarball_extracts},${has_package_dir},${has_package_json},${name_match},${version_match},${file_count},${tarball_size},${attestation_count},${unique_hashes},${verdict}" >> "$RESULTS"
    rm -rf "$TMPDIR"
    return
  fi

  # 2. Download tarball
  local TARBALL="${TMPDIR}/pkg.tgz"
  local HTTP_CODE
  HTTP_CODE=$(curl -sL -o "$TARBALL" -w '%{http_code}' "$TARBALL_URL" 2>/dev/null) || HTTP_CODE="000"

  if [ "$HTTP_CODE" = "200" ] && [ -f "$TARBALL" ]; then
    tarball_downloads="true"
    tarball_size=$(wc -c < "$TARBALL" | tr -d ' ')
  else
    echo "${IDX}/${TOTAL} SKIP ${PKG}@${VERSION} — tarball HTTP ${HTTP_CODE}" >> "$LOG"
    echo "\"${PKG}\",\"${VERSION}\",${manifest_exists},${tarball_downloads},${sha1_match},${sha512_match},${tarball_extracts},${has_package_dir},${has_package_json},${name_match},${version_match},${file_count},${tarball_size},${attestation_count},${unique_hashes},${verdict}" >> "$RESULTS"
    rm -rf "$TMPDIR"
    return
  fi

  # 3. SHA-1
  if [ -n "$M_SHASUM" ]; then
    local ACTUAL_SHA1
    ACTUAL_SHA1=$(shasum -a 1 "$TARBALL" | cut -d' ' -f1)
    if [ "$M_SHASUM" = "$ACTUAL_SHA1" ]; then
      sha1_match="true"
    else
      sha1_match="false"
    fi
  fi

  # 4. SHA-512 / integrity
  if [ -n "$M_INTEGRITY" ]; then
    local ALGO M_B64
    ALGO=$(echo "$M_INTEGRITY" | cut -d- -f1)
    M_B64=$(echo "$M_INTEGRITY" | cut -d- -f2-)

    if [ "$ALGO" = "sha512" ]; then
      local ACTUAL_HEX ACTUAL_B64
      ACTUAL_HEX=$(shasum -a 512 "$TARBALL" | cut -d' ' -f1)
      ACTUAL_B64=$(echo "$ACTUAL_HEX" | xxd -r -p | base64 | tr -d '\n')
      if [ "$M_B64" = "$ACTUAL_B64" ]; then
        sha512_match="true"
      else
        sha512_match="false"
      fi
    elif [ "$ALGO" = "sha256" ]; then
      local ACTUAL_HEX ACTUAL_B64
      ACTUAL_HEX=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
      ACTUAL_B64=$(echo "$ACTUAL_HEX" | xxd -r -p | base64 | tr -d '\n')
      if [ "$M_B64" = "$ACTUAL_B64" ]; then
        sha512_match="true"
      else
        sha512_match="false"
      fi
    fi
  fi

  # 5. Tarball structure
  local EXTRACT="${TMPDIR}/extract"
  mkdir -p "$EXTRACT"

  if tar xzf "$TARBALL" -C "$EXTRACT" 2>/dev/null; then
    tarball_extracts="true"

    if [ -d "${EXTRACT}/package" ]; then
      has_package_dir="true"

      if [ -f "${EXTRACT}/package/package.json" ]; then
        has_package_json="true"

        local INNER_NAME INNER_VERSION
        INNER_NAME=$(jq -r '.name // ""' "${EXTRACT}/package/package.json" 2>/dev/null || echo "")
        INNER_VERSION=$(jq -r '.version // ""' "${EXTRACT}/package/package.json" 2>/dev/null || echo "")

        if [ -n "$INNER_NAME" ]; then
          [ "$INNER_NAME" = "$PKG" ] && name_match="true" || name_match="false"
        fi
        if [ -n "$INNER_VERSION" ]; then
          [ "$INNER_VERSION" = "$VERSION" ] && version_match="true" || version_match="false"
        fi
      fi

      file_count=$(find "${EXTRACT}/package" -type f 2>/dev/null | wc -l | tr -d ' ')
    fi
  fi

  # 6. Attestations
  local ATTEST_JSON
  ATTEST_JSON=$(curl -sf "https://registry.npmjs.org/-/npm/v1/attestations/${PKG}@${VERSION}" 2>/dev/null || echo '{"attestations":[]}')
  attestation_count=$(echo "$ATTEST_JSON" | jq '.attestations | length' 2>/dev/null || echo 0)

  if [ "$attestation_count" -gt 0 ]; then
    unique_hashes=$(echo "$ATTEST_JSON" | python3 -c "
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
" 2>/dev/null || echo "0")
  fi

  # 7. Verdict
  if [ "$sha1_match" = "false" ] || [ "$sha512_match" = "false" ]; then
    verdict="MISMATCH"
  elif [ "$sha1_match" = "true" ] && [ "$sha512_match" = "true" ]; then
    verdict="PASS"
  elif [ "$sha1_match" = "true" ] && [ "$sha512_match" = "n/a" ]; then
    verdict="PASS"
  elif [ "$sha1_match" = "n/a" ] && [ "$sha512_match" = "true" ]; then
    verdict="PASS"
  else
    verdict="UNKNOWN"
  fi

  local MARKER=" "
  [ "$verdict" = "MISMATCH" ] && MARKER="!"
  [ "$verdict" = "PASS" ] && MARKER="+"

  echo "${IDX}/${TOTAL} [${MARKER}] ${PKG}@${VERSION} — ${verdict} (sha1=${sha1_match} sha512=${sha512_match} attest=${attestation_count} hashes=${unique_hashes})" >> "$LOG"
  echo "${IDX}/${TOTAL} [${MARKER}] ${PKG}@${VERSION} — ${verdict} (sha1=${sha1_match} sha512=${sha512_match} attest=${attestation_count} hashes=${unique_hashes})"

  echo "\"${PKG}\",\"${VERSION}\",${manifest_exists},${tarball_downloads},${sha1_match},${sha512_match},${tarball_extracts},${has_package_dir},${has_package_json},${name_match},${version_match},${file_count},${tarball_size},${attestation_count},${unique_hashes},${verdict}" >> "$RESULTS"

  rm -rf "$TMPDIR"
}

export -f check_pkg

IDX=0
PIDS=()

while IFS=, read -r NAME VERSION; do
  NAME=$(echo "$NAME" | tr -d '"')
  VERSION=$(echo "$VERSION" | tr -d '"')
  [ -z "$NAME" ] || [ -z "$VERSION" ] && continue

  IDX=$((IDX + 1))

  check_pkg "$NAME" "$VERSION" "$IDX" "$TOTAL" "$RESULTS" "$LOG" &
  PIDS+=($!)

  if [ ${#PIDS[@]} -ge "$CONCURRENCY" ]; then
    wait "${PIDS[0]}" 2>/dev/null || true
    PIDS=("${PIDS[@]:1}")
  fi
done < <(tail -n +2 "$CSV")

for PID in "${PIDS[@]}"; do
  wait "$PID" 2>/dev/null || true
done

echo ""
echo "=== Scan Complete ==="

TOTAL_CHECKED=$(tail -n +2 "$RESULTS" | grep -c '.' || echo 0)
MISMATCHES=$(tail -n +2 "$RESULTS" | grep -c ',MISMATCH$' || echo 0)
PASSES=$(tail -n +2 "$RESULTS" | grep -c ',PASS$' || echo 0)
ERRORS=$(tail -n +2 "$RESULTS" | grep -c ',error$' || echo 0)
UNKNOWNS=$(tail -n +2 "$RESULTS" | grep -c ',UNKNOWN$' || echo 0)
WITH_ATTEST=$(awk -F, 'NR>1 && $(NF-2)+0 > 0' "$RESULTS" | wc -l | tr -d ' ')
MULTI_HASH=$(awk -F, 'NR>1 && $(NF-1)+0 > 1' "$RESULTS" | wc -l | tr -d ' ')

echo "Checked:               $TOTAL_CHECKED"
echo "Integrity MISMATCH:    $MISMATCHES"
echo "Integrity PASS:        $PASSES"
echo "Errors/skipped:        $ERRORS"
echo "Unknown:               $UNKNOWNS"
echo "With attestations:     $WITH_ATTEST"
echo "Multi-hash (dual pub): $MULTI_HASH"
echo ""
echo "Results:  $RESULTS"
echo "Log:      $LOG"
