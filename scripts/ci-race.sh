#!/bin/bash
set -euo pipefail

BASE_VERSION="$1"
A_TOKEN="$2"
A_PROVENANCE="$3"
B_TOKEN="$4"
B_PROVENANCE="$5"
TIMING="${6:-concurrent}"
DELAY="${7:-0}"
ROUNDS="${8:-5}"

REPO_URL="https://github.com/darcyclarke/ghostpublish"
PKG="ghostpublish"

A_PROV_FLAG="--no-provenance"
[ "$A_PROVENANCE" = "true" ] && A_PROV_FLAG="--provenance"

B_PROV_FLAG="--no-provenance"
[ "$B_PROVENANCE" = "true" ] && B_PROV_FLAG="--provenance"

echo "A provenance: $A_PROVENANCE ($A_PROV_FLAG)"
echo "B provenance: $B_PROVENANCE ($B_PROV_FLAG)"
echo "Timing: $TIMING (delay: ${DELAY}s)"
echo "Rounds: $ROUNDS"
echo "Tokens same: $([ "$A_TOKEN" = "$B_TOKEN" ] && echo 'yes' || echo 'no')"
echo ""

declare -a RESULTS
A_WIN=0; B_WIN=0; BOTH_WIN=0; BOTH_FAIL=0
MISMATCH_COUNT=0; MATCH_COUNT=0
ORPHAN_SIGSTORE=0

for R in $(seq 1 "$ROUNDS"); do
  VERSION="${BASE_VERSION}.r${R}"
  echo "=========================================="
  echo "Round $R/$ROUNDS — $VERSION"
  echo "=========================================="

  rm -rf /tmp/pkg-a /tmp/pkg-b
  mkdir -p /tmp/pkg-a /tmp/pkg-b

  echo "{\"name\": \"$PKG\", \"version\": \"${VERSION}\", \"description\": \"variant A\", \"repository\": {\"type\": \"git\", \"url\": \"$REPO_URL\"}}" > /tmp/pkg-a/package.json
  echo "// A: $(openssl rand -hex 16)" > /tmp/pkg-a/index.js
  echo "//registry.npmjs.org/:_authToken=${A_TOKEN}" > /tmp/pkg-a/.npmrc

  echo "{\"name\": \"$PKG\", \"version\": \"${VERSION}\", \"description\": \"variant B\", \"repository\": {\"type\": \"git\", \"url\": \"$REPO_URL\"}}" > /tmp/pkg-b/package.json
  echo "// B: $(openssl rand -hex 16)" > /tmp/pkg-b/index.js
  echo "//registry.npmjs.org/:_authToken=${B_TOKEN}" > /tmp/pkg-b/.npmrc

  A_INTEGRITY=$(cd /tmp/pkg-a && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
  B_INTEGRITY=$(cd /tmp/pkg-b && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
  rm -f /tmp/pkg-a/*.tgz /tmp/pkg-b/*.tgz

  set +e

  if [ "$TIMING" = "concurrent" ]; then
    (cd /tmp/pkg-a && npm publish --access public --tag latest $A_PROV_FLAG 2>&1 | tee /tmp/publish-a.log) &
    PID_A=$!
    (cd /tmp/pkg-b && npm publish --access public --tag latest $B_PROV_FLAG 2>&1 | tee /tmp/publish-b.log) &
    PID_B=$!
    wait $PID_A; EXIT_A=$?
    wait $PID_B; EXIT_B=$?
  elif [ "$TIMING" = "b-first" ]; then
    (cd /tmp/pkg-b && npm publish --access public --tag latest $B_PROV_FLAG 2>&1 | tee /tmp/publish-b.log) &
    PID_B=$!
    sleep "$DELAY"
    (cd /tmp/pkg-a && npm publish --access public --tag latest $A_PROV_FLAG 2>&1 | tee /tmp/publish-a.log) &
    PID_A=$!
    wait $PID_B; EXIT_B=$?
    wait $PID_A; EXIT_A=$?
  elif [ "$TIMING" = "a-first" ]; then
    (cd /tmp/pkg-a && npm publish --access public --tag latest $A_PROV_FLAG 2>&1 | tee /tmp/publish-a.log) &
    PID_A=$!
    sleep "$DELAY"
    (cd /tmp/pkg-b && npm publish --access public --tag latest $B_PROV_FLAG 2>&1 | tee /tmp/publish-b.log) &
    PID_B=$!
    wait $PID_A; EXIT_A=$?
    wait $PID_B; EXIT_B=$?
  fi

  set -e

  A_OK=0; B_OK=0
  [ $EXIT_A -eq 0 ] && A_OK=1
  [ $EXIT_B -eq 0 ] && B_OK=1

  WINNER="none"
  if [ $A_OK -eq 1 ] && [ $B_OK -eq 1 ]; then
    WINNER="BOTH"; BOTH_WIN=$((BOTH_WIN+1))
  elif [ $A_OK -eq 1 ]; then
    WINNER="A"; A_WIN=$((A_WIN+1))
  elif [ $B_OK -eq 1 ]; then
    WINNER="B"; B_WIN=$((B_WIN+1))
  else
    WINNER="NONE"; BOTH_FAIL=$((BOTH_FAIL+1))
  fi

  INTEGRITY_STATUS="-"
  ATTEST_INFO="-"
  CDN_VARIANT="-"
  SIGSTORE_ORPHAN="no"

  if [ $A_OK -eq 1 ] || [ $B_OK -eq 1 ]; then
    sleep 8

    MANIFEST=$(curl -s "https://registry.npmjs.org/$PKG/${VERSION}")
    M_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // "null"')
    M_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // "null"')

    if [ "$M_SHASUM" != "null" ]; then
      curl -sL "https://registry.npmjs.org/$PKG/-/$PKG-${VERSION}.tgz" -o /tmp/dl.tgz
      T_SHA1=$(sha1sum /tmp/dl.tgz | cut -d' ' -f1)
      T_INTEGRITY="sha512-$(sha512sum -b /tmp/dl.tgz | cut -d' ' -f1 | xxd -r -p | base64 -w 0)"

      if [ "$M_SHASUM" = "$T_SHA1" ] && [ "$M_INTEGRITY" = "$T_INTEGRITY" ]; then
        INTEGRITY_STATUS="consistent"
        MATCH_COUNT=$((MATCH_COUNT+1))
      else
        INTEGRITY_STATUS="MISMATCH"
        MISMATCH_COUNT=$((MISMATCH_COUNT+1))
      fi

      mkdir -p /tmp/ex && rm -rf /tmp/ex/*
      tar xzf /tmp/dl.tgz -C /tmp/ex
      CDN_DESC=$(jq -r .description /tmp/ex/package/package.json)
      [ "$CDN_DESC" = "variant A" ] && CDN_VARIANT="A" || CDN_VARIANT="B"
    fi

    ATTEST_JSON=$(curl -s "https://registry.npmjs.org/-/npm/v1/attestations/$PKG@${VERSION}")
    ATTEST_COUNT=$(echo "$ATTEST_JSON" | python3 -c "
import json, sys, base64
data = json.load(sys.stdin)
attestations = data.get('attestations', [])
hashes = set()
for a in attestations:
  payload = a.get('bundle', {}).get('dsseEnvelope', {}).get('payload', '')
  if payload:
    pred = json.loads(base64.b64decode(payload))
    for s in pred.get('subject', []):
      for algo, digest in s.get('digest', {}).items():
        hashes.add(digest)
print(f'{len(attestations)}:{len(hashes)}')
" 2>/dev/null || echo "0:0")
    ATTEST_INFO="$ATTEST_COUNT"
  fi

  if grep -q "Sigstore" /tmp/publish-b.log 2>/dev/null && [ $B_OK -eq 0 ]; then
    SIGSTORE_ORPHAN="yes"
    ORPHAN_SIGSTORE=$((ORPHAN_SIGSTORE+1))
  fi
  if grep -q "Sigstore" /tmp/publish-a.log 2>/dev/null && [ $A_OK -eq 0 ]; then
    SIGSTORE_ORPHAN="yes"
    ORPHAN_SIGSTORE=$((ORPHAN_SIGSTORE+1))
  fi

  B_ERR="-"
  if [ $B_OK -eq 0 ]; then
    B_ERR=$(grep -oP 'E\d{3}' /tmp/publish-b.log 2>/dev/null | head -1 || echo "-")
  fi
  A_ERR="-"
  if [ $A_OK -eq 0 ]; then
    A_ERR=$(grep -oP 'E\d{3}' /tmp/publish-a.log 2>/dev/null | head -1 || echo "-")
  fi

  RESULT_LINE="R${R}: winner=${WINNER} | A=${EXIT_A}(${A_ERR}) B=${EXIT_B}(${B_ERR}) | integrity=${INTEGRITY_STATUS} | cdn=${CDN_VARIANT} | attest=${ATTEST_INFO} | orphan_sigstore=${SIGSTORE_ORPHAN}"
  RESULTS+=("$RESULT_LINE")
  echo "$RESULT_LINE"
  echo ""

  sleep 2
done

echo ""
echo "============================================"
echo "SUMMARY ($ROUNDS rounds)"
echo "============================================"
echo ""
for LINE in "${RESULTS[@]}"; do
  echo "  $LINE"
done
echo ""
echo "A won: $A_WIN/$ROUNDS"
echo "B won: $B_WIN/$ROUNDS"
echo "Both won (race triggered): $BOTH_WIN/$ROUNDS"
echo "Both failed: $BOTH_FAIL/$ROUNDS"
echo "Integrity mismatches: $MISMATCH_COUNT"
echo "Integrity consistent: $MATCH_COUNT"
echo "Orphaned Sigstore entries: $ORPHAN_SIGSTORE"
