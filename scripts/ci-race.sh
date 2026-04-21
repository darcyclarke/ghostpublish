#!/bin/bash
set -euo pipefail

VERSION="$1"
A_TOKEN="$2"
A_PROVENANCE="$3"
B_TOKEN="$4"
B_PROVENANCE="$5"
TIMING="${6:-concurrent}"
DELAY="${7:-0}"

REPO_URL="https://github.com/darcyclarke/ghostpublish"
PKG="ghostpublish"

rm -rf /tmp/pkg-a && mkdir -p /tmp/pkg-a
echo "{\"name\": \"$PKG\", \"version\": \"${VERSION}\", \"description\": \"variant A\", \"repository\": {\"type\": \"git\", \"url\": \"$REPO_URL\"}}" > /tmp/pkg-a/package.json
echo "// A: $(openssl rand -hex 16)" > /tmp/pkg-a/index.js
echo "//registry.npmjs.org/:_authToken=${A_TOKEN}" > /tmp/pkg-a/.npmrc

rm -rf /tmp/pkg-b && mkdir -p /tmp/pkg-b
echo "{\"name\": \"$PKG\", \"version\": \"${VERSION}\", \"description\": \"variant B\", \"repository\": {\"type\": \"git\", \"url\": \"$REPO_URL\"}}" > /tmp/pkg-b/package.json
echo "// B: $(openssl rand -hex 16)" > /tmp/pkg-b/index.js
echo "//registry.npmjs.org/:_authToken=${B_TOKEN}" > /tmp/pkg-b/.npmrc

echo "A: $(cat /tmp/pkg-a/index.js)"
echo "B: $(cat /tmp/pkg-b/index.js)"
echo "A provenance: $A_PROVENANCE"
echo "B provenance: $B_PROVENANCE"
echo "Timing: $TIMING (delay: ${DELAY}s)"
echo ""

A_INTEGRITY=$(cd /tmp/pkg-a && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
B_INTEGRITY=$(cd /tmp/pkg-b && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
rm -f /tmp/pkg-a/*.tgz /tmp/pkg-b/*.tgz
echo "A integrity: $A_INTEGRITY"
echo "B integrity: $B_INTEGRITY"
echo ""

A_PROV_FLAG="--no-provenance"
[ "$A_PROVENANCE" = "true" ] && A_PROV_FLAG="--provenance"

B_PROV_FLAG="--no-provenance"
[ "$B_PROVENANCE" = "true" ] && B_PROV_FLAG="--provenance"

launch_a() {
  (cd /tmp/pkg-a && npm publish --access public --tag latest $A_PROV_FLAG 2>&1 | tee /tmp/publish-a.log)
}

launch_b() {
  (cd /tmp/pkg-b && npm publish --access public --tag latest $B_PROV_FLAG 2>&1 | tee /tmp/publish-b.log)
}

set +e

if [ "$TIMING" = "concurrent" ]; then
  launch_a &
  PID_A=$!
  launch_b &
  PID_B=$!
  wait $PID_A; EXIT_A=$?
  wait $PID_B; EXIT_B=$?

elif [ "$TIMING" = "b-first" ]; then
  launch_b &
  PID_B=$!
  sleep "$DELAY"
  launch_a &
  PID_A=$!
  wait $PID_B; EXIT_B=$?
  wait $PID_A; EXIT_A=$?

elif [ "$TIMING" = "a-first" ]; then
  launch_a &
  PID_A=$!
  sleep "$DELAY"
  launch_b &
  PID_B=$!
  wait $PID_A; EXIT_A=$?
  wait $PID_B; EXIT_B=$?

else
  echo "Unknown timing: $TIMING"
  exit 1
fi

set -e

echo ""
echo "=== Results ==="
echo "A exit: $EXIT_A"
echo "B exit: $EXIT_B"
echo ""
echo "--- A output ---"
cat /tmp/publish-a.log
echo ""
echo "--- B output ---"
cat /tmp/publish-b.log
echo ""

A_OK=0; B_OK=0
[ $EXIT_A -eq 0 ] && A_OK=1
[ $EXIT_B -eq 0 ] && B_OK=1

if [ "$A_OK" -eq 1 ] && [ "$B_OK" -eq 1 ]; then
  echo "BOTH SUCCEEDED"
elif [ "$A_OK" -eq 1 ]; then
  echo "Only A succeeded"
elif [ "$B_OK" -eq 1 ]; then
  echo "Only B succeeded"
else
  echo "Both failed"
fi

sleep 10

echo ""
MANIFEST=$(curl -s "https://registry.npmjs.org/$PKG/${VERSION}")
M_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // "null"')
M_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // "null"')
echo "dist.integrity: $M_INTEGRITY"
echo "dist.shasum:    $M_SHASUM"

if [ "$M_SHASUM" != "null" ]; then
  curl -sL "https://registry.npmjs.org/$PKG/-/$PKG-${VERSION}.tgz" -o /tmp/dl.tgz
  T_SHA1=$(sha1sum /tmp/dl.tgz | cut -d' ' -f1)
  T_INTEGRITY="sha512-$(sha512sum -b /tmp/dl.tgz | cut -d' ' -f1 | xxd -r -p | base64 -w 0)"

  echo "tarball sha1:      $T_SHA1"
  echo "tarball integrity: $T_INTEGRITY"

  [ "$M_SHASUM" = "$T_SHA1" ] && echo "SHA-1: MATCH" || echo "SHA-1: MISMATCH"
  [ "$M_INTEGRITY" = "$T_INTEGRITY" ] && echo "SHA-512: MATCH" || echo "SHA-512: MISMATCH"

  mkdir -p /tmp/ex && rm -rf /tmp/ex/*
  tar xzf /tmp/dl.tgz -C /tmp/ex
  echo "index.js: $(cat /tmp/ex/package/index.js)"
  echo "description: $(jq -r .description /tmp/ex/package/package.json)"
fi

echo ""
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
echo "Manifest matches A: $([ "$M_INTEGRITY" = "$A_INTEGRITY" ] && echo 'YES' || echo 'NO')"
echo "Manifest matches B: $([ "$M_INTEGRITY" = "$B_INTEGRITY" ] && echo 'YES' || echo 'NO')"
