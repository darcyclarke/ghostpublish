#!/bin/bash
set -euo pipefail

VERSION="$1"
MODE="$2"
DELAY="${3:-0}"

REPO_URL="https://github.com/darcyclarke/ghostpublish"
PKG="ghostpublish"

rm -rf /tmp/pkg-unsigned && mkdir -p /tmp/pkg-unsigned
echo "{\"name\": \"$PKG\", \"version\": \"${VERSION}\", \"description\": \"variant unsigned\", \"repository\": {\"type\": \"git\", \"url\": \"$REPO_URL\"}}" > /tmp/pkg-unsigned/package.json
echo "// UNSIGNED: $(openssl rand -hex 16)" > /tmp/pkg-unsigned/index.js

rm -rf /tmp/pkg-signed && mkdir -p /tmp/pkg-signed
echo "{\"name\": \"$PKG\", \"version\": \"${VERSION}\", \"description\": \"variant signed\", \"repository\": {\"type\": \"git\", \"url\": \"$REPO_URL\"}}" > /tmp/pkg-signed/package.json
echo "// SIGNED: $(openssl rand -hex 16)" > /tmp/pkg-signed/index.js

echo "Unsigned content: $(cat /tmp/pkg-unsigned/index.js)"
echo "Signed content:   $(cat /tmp/pkg-signed/index.js)"
echo "Mode: $MODE (delay: ${DELAY}s)"
echo ""

U_INTEGRITY=$(cd /tmp/pkg-unsigned && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
S_INTEGRITY=$(cd /tmp/pkg-signed && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
rm -f /tmp/pkg-unsigned/*.tgz /tmp/pkg-signed/*.tgz
echo "Unsigned integrity: $U_INTEGRITY"
echo "Signed integrity:   $S_INTEGRITY"
echo ""

launch_unsigned() {
  (cd /tmp/pkg-unsigned && npm publish --access public --tag ci --no-provenance 2>&1 | tee /tmp/publish-unsigned.log)
}

launch_signed() {
  (cd /tmp/pkg-signed && npm publish --access public --tag ci --provenance 2>&1 | tee /tmp/publish-signed.log)
}

set +e

if [ "$MODE" = "concurrent" ]; then
  echo "=== Launching both simultaneously ==="
  launch_unsigned &
  PID_U=$!
  launch_signed &
  PID_S=$!
  wait $PID_U; EXIT_U=$?
  wait $PID_S; EXIT_S=$?

elif [ "$MODE" = "signed-first" ]; then
  echo "=== Launching signed first, unsigned after ${DELAY}s ==="
  launch_signed &
  PID_S=$!
  sleep "$DELAY"
  launch_unsigned &
  PID_U=$!
  wait $PID_S; EXIT_S=$?
  wait $PID_U; EXIT_U=$?

elif [ "$MODE" = "unsigned-first" ]; then
  echo "=== Launching unsigned first, signed after ${DELAY}s ==="
  launch_unsigned &
  PID_U=$!
  sleep "$DELAY"
  launch_signed &
  PID_S=$!
  wait $PID_U; EXIT_U=$?
  wait $PID_S; EXIT_S=$?

else
  echo "Unknown mode: $MODE"
  exit 1
fi

set -e

echo ""
echo "=== Publish Results ==="
echo "Unsigned exit: $EXIT_U"
echo "Signed exit:   $EXIT_S"
echo ""
echo "--- Unsigned output ---"
cat /tmp/publish-unsigned.log
echo ""
echo "--- Signed output ---"
cat /tmp/publish-signed.log
echo ""

U_OK=0; S_OK=0
[ $EXIT_U -eq 0 ] && U_OK=1
[ $EXIT_S -eq 0 ] && S_OK=1

if [ "$U_OK" -eq 1 ] && [ "$S_OK" -eq 1 ]; then
  echo "BOTH SUCCEEDED"
elif [ "$U_OK" -eq 1 ]; then
  echo "Only unsigned succeeded"
elif [ "$S_OK" -eq 1 ]; then
  echo "Only signed succeeded"
else
  echo "Both failed"
fi

sleep 10

echo ""
echo "=== Registry State ==="
MANIFEST=$(curl -s "https://registry.npmjs.org/$PKG/${VERSION}")
M_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // "null"')
M_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // "null"')
echo "dist.integrity: $M_INTEGRITY"
echo "dist.shasum:    $M_SHASUM"

if [ "$M_SHASUM" != "null" ]; then
  curl -sL "https://registry.npmjs.org/$PKG/-/$PKG-${VERSION}.tgz" -o /tmp/dl.tgz
  T_SHA1=$(sha1sum /tmp/dl.tgz | cut -d' ' -f1)
  T_INTEGRITY="sha512-$(sha512sum -b /tmp/dl.tgz | cut -d' ' -f1 | xxd -r -p | base64)"

  echo "tarball sha1:      $T_SHA1"
  echo "tarball integrity: $T_INTEGRITY"

  [ "$M_SHASUM" = "$T_SHA1" ] && echo "SHA-1: MATCH" || echo "SHA-1: MISMATCH"
  [ "$M_INTEGRITY" = "$T_INTEGRITY" ] && echo "SHA-512: MATCH" || echo "SHA-512: MISMATCH"

  mkdir -p /tmp/ex && rm -rf /tmp/ex/*
  tar xzf /tmp/dl.tgz -C /tmp/ex
  WINNER_CONTENT=$(cat /tmp/ex/package/index.js)
  echo "index.js: $WINNER_CONTENT"
  echo "description: $(jq -r .description /tmp/ex/package/package.json)"

  if echo "$WINNER_CONTENT" | grep -q "UNSIGNED"; then
    echo ""
    echo ">>> UNSIGNED TARBALL WON THE CDN <<<"
  elif echo "$WINNER_CONTENT" | grep -q "SIGNED"; then
    echo ""
    echo ">>> SIGNED TARBALL WON THE CDN <<<"
  fi
fi

echo ""
echo "=== Attestations ==="
ATTESTATIONS=$(curl -s "https://registry.npmjs.org/-/npm/v1/attestations/$PKG@${VERSION}")
echo "$ATTESTATIONS" | python3 -c "
import json, sys, base64
data = json.load(sys.stdin)
attestations = data.get('attestations', [])
if not attestations:
  print(f'No attestations: {data.get(\"error\", \"none\")}')
  sys.exit(0)
print(f'Attestations: {len(attestations)}')
hashes = set()
for i, a in enumerate(attestations):
  pred_type = a.get('predicateType', 'N/A').split('/')[-1]
  payload = a.get('bundle', {}).get('dsseEnvelope', {}).get('payload', '')
  if payload:
    pred = json.loads(base64.b64decode(payload))
    for s in pred.get('subject', []):
      for algo, digest in s.get('digest', {}).items():
        hashes.add(digest)
        print(f'  {i+1} [{pred_type}]: {algo}={digest[:40]}...')
print(f'Unique hashes: {len(hashes)}')
"

echo ""
echo "=== Analysis ==="
echo "Manifest matches unsigned: $([ "$M_INTEGRITY" = "$U_INTEGRITY" ] && echo 'YES' || echo 'NO')"
echo "Manifest matches signed:   $([ "$M_INTEGRITY" = "$S_INTEGRITY" ] && echo 'YES' || echo 'NO')"

if [ "$M_SHASUM" != "null" ]; then
  echo ""
  if echo "$WINNER_CONTENT" | grep -q "UNSIGNED" && [ "$S_OK" -eq 1 ]; then
    echo "SCENARIO: Unsigned tarball on CDN + signed publish also succeeded"
    echo "  Attestations may reference the signed hash, but CDN serves unsigned content"
  elif echo "$WINNER_CONTENT" | grep -q "SIGNED" && [ "$U_OK" -eq 1 ]; then
    echo "SCENARIO: Signed tarball on CDN + unsigned publish also succeeded"
    echo "  Manifest integrity may reference unsigned hash, mismatching the signed tarball"
  fi
fi
