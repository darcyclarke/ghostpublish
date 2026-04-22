#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results"

PKG="ghostpublish"
TAG="pubcache"
TIMESTAMP=$(date +%s)
VERSION="1.0.0-pubcache.${TIMESTAMP}"

mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/publish-cache-$(date +%Y%m%d-%H%M%S).log"

log() { echo "$@" | tee -a "$RESULT_FILE"; }

log "=== Publish Cache & Hash Verification Test ==="
log "Package: $PKG@$VERSION"
log "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log ""
log "Tests:"
log "  1. Does the npm client pre-compute integrity values?"
log "  2. Does the registry store them faithfully (no server-side recomputation)?"
log "  3. Does npm publish cache data locally that npm install could reuse?"
log ""

NPM_CACHE_DIR=$(npm config get cache 2>/dev/null || echo "$HOME/.npm")
log "npm cache dir: $NPM_CACHE_DIR"
log ""

npm cache clean --force 2>/dev/null || true
log "[1/7] Cache cleaned"
log ""

STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR" /tmp/pubcache-test-*' EXIT

cat > "$STAGE_DIR/package.json" << EOF
{
  "name": "$PKG",
  "version": "$VERSION",
  "description": "publish cache test — $TIMESTAMP",
  "main": "index.js"
}
EOF
echo "module.exports = 'pubcache-${TIMESTAMP}';" > "$STAGE_DIR/index.js"

log "[2/7] Publishing $PKG@$VERSION..."
PUBLISH_OUT=$(cd "$STAGE_DIR" && npm publish --tag "$TAG" --access public 2>&1)

PUB_SHASUM=$(echo "$PUBLISH_OUT" | grep 'shasum:' | awk '{print $NF}')
PUB_INTEGRITY=$(echo "$PUBLISH_OUT" | grep 'integrity:' | awk '{print $NF}')
PUB_SIZE=$(echo "$PUBLISH_OUT" | grep 'package size:' | sed 's/.*package size: //' | sed 's/ *$//')

log "  publish output shasum:    $PUB_SHASUM"
log "  publish output integrity: $PUB_INTEGRITY"
log "  publish output size:      $PUB_SIZE"
log ""

log "[3/7] Waiting for registry propagation..."
sleep 5

MANIFEST=$(curl -sf "https://registry.npmjs.org/${PKG}/${VERSION}" 2>/dev/null) || {
  log "  FAIL: could not fetch manifest"
  exit 1
}
REG_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // ""')
REG_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // ""')
TARBALL_URL=$(echo "$MANIFEST" | jq -r '.dist.tarball // ""')

log "  registry shasum:    $REG_SHASUM"
log "  registry integrity: $REG_INTEGRITY"
log "  tarball URL:        $TARBALL_URL"
log ""

log "[4/7] Downloading tarball from CDN..."
CDN_TARBALL=$(mktemp)
curl -sL -o "$CDN_TARBALL" "$TARBALL_URL"
CDN_SIZE=$(wc -c < "$CDN_TARBALL" | tr -d ' ')
CDN_SHA1=$(shasum -a 1 "$CDN_TARBALL" | cut -d' ' -f1)
CDN_SHA512_HEX=$(shasum -a 512 "$CDN_TARBALL" | cut -d' ' -f1)
CDN_INTEGRITY="sha512-$(echo "$CDN_SHA512_HEX" | xxd -r -p | base64 | tr -d '\n')"

log "  CDN tarball sha1:      $CDN_SHA1"
log "  CDN tarball integrity: $CDN_INTEGRITY"
log "  CDN tarball size:      $CDN_SIZE bytes"
log ""

log "[5/7] Three-way comparison..."
log ""

ALL_MATCH="true"

if [ "$PUB_SHASUM" = "$REG_SHASUM" ] && [ "$REG_SHASUM" = "$CDN_SHA1" ]; then
  log "  SHA-1:   ALL MATCH (publish output = registry = CDN tarball)"
else
  log "  SHA-1:   DIVERGENCE"
  log "    publish output: $PUB_SHASUM"
  log "    registry:       $REG_SHASUM"
  log "    CDN tarball:    $CDN_SHA1"
  ALL_MATCH="false"
fi

if [ "$PUB_INTEGRITY" = "$REG_INTEGRITY" ] && [ "$REG_INTEGRITY" = "$CDN_INTEGRITY" ]; then
  log "  SHA-512: ALL MATCH (publish output = registry = CDN tarball)"
else
  log "  SHA-512: DIVERGENCE"
  log "    publish output: $PUB_INTEGRITY"
  log "    registry:       $REG_INTEGRITY"
  log "    CDN tarball:    $CDN_INTEGRITY"
  ALL_MATCH="false"
fi
log ""

if [ "$ALL_MATCH" = "true" ]; then
  log "  CONFIRMED: Client pre-computes hashes, registry stores them faithfully,"
  log "  and CDN serves the exact tarball the client uploaded."
else
  log "  WARNING: Hash divergence detected — possible race or server-side mutation."
fi
log ""

log "[6/7] Inspecting npm cache after publish..."

CACHED_TARBALL_BLOB="false"
if [ -d "$NPM_CACHE_DIR/_cacache/content-v2" ]; then
  while IFS= read -r blob; do
    BLOB_SIZE=$(wc -c < "$blob" | tr -d ' ')
    BLOB_SHA1=$(shasum -a 1 "$blob" | cut -d' ' -f1)
    if [ "$BLOB_SHA1" = "$CDN_SHA1" ]; then
      log "  FOUND: cached content blob matches CDN tarball"
      log "    path: $blob"
      log "    sha1: $BLOB_SHA1 (matches)"
      log "    size: $BLOB_SIZE bytes"
      CACHED_TARBALL_BLOB="true"
    fi
  done < <(find "$NPM_CACHE_DIR/_cacache/content-v2" -type f 2>/dev/null)
fi

HAS_URL_INDEX="false"
if [ -d "$NPM_CACHE_DIR/_cacache/index-v5" ]; then
  INDEX_MATCH=$(find "$NPM_CACHE_DIR/_cacache/index-v5" -type f -exec grep -l "registry.npmjs.org" {} \; 2>/dev/null | head -1 || true)
  if [ -n "$INDEX_MATCH" ]; then
    HAS_URL_INDEX="true"
    log "  FOUND: cache index entry referencing registry URL"
  fi
fi

log ""
log "  tarball blob in cache:        $CACHED_TARBALL_BLOB"
log "  registry URL in cache index:  $HAS_URL_INDEX"
log ""

if [ "$CACHED_TARBALL_BLOB" = "true" ] && [ "$HAS_URL_INDEX" = "false" ]; then
  log "  The tarball content IS cached (content-addressed blob), but there is"
  log "  no index entry mapping the registry URL to it. npm install looks up"
  log "  cache entries by URL key, so it would not find this blob through"
  log "  normal cache resolution."
fi
log ""

log "[7/7] Testing npm install from same machine..."

INSTALL_DIR=$(mktemp -d /tmp/pubcache-test-install-XXXX)
cat > "$INSTALL_DIR/package.json" << EOF
{"name":"pubcache-consumer","version":"1.0.0","private":true}
EOF

INSTALL_EXIT=0
INSTALL_OUT=$( (cd "$INSTALL_DIR" && npm install "$PKG@$VERSION" 2>&1) ) || INSTALL_EXIT=$?

log "  exit code: $INSTALL_EXIT"
if [ $INSTALL_EXIT -eq 0 ]; then
  log "  result: INSTALLED"
  LOCKFILE_INT=$(jq -r ".packages[\"node_modules/$PKG\"].integrity // empty" "$INSTALL_DIR/package-lock.json" 2>/dev/null || echo "")
  log "  lockfile integrity: $LOCKFILE_INT"

  if [ "$LOCKFILE_INT" = "$REG_INTEGRITY" ]; then
    log "  lockfile matches registry integrity"
  fi
else
  log "  result: REJECTED"
  log "  output: $(echo "$INSTALL_OUT" | grep -i 'integrity\|EINTEGRITY\|ERR' | head -3)"
fi
log ""

log "=== Summary ==="
log ""
log "Client pre-computes hashes:     $([ "$ALL_MATCH" = "true" ] && echo 'CONFIRMED' || echo 'DIVERGENCE DETECTED')"
log "Registry stores them faithfully: $([ "$ALL_MATCH" = "true" ] && echo 'CONFIRMED' || echo 'UNCLEAR')"
log "Publish caches tarball blob:     $CACHED_TARBALL_BLOB"
log "Cache indexed by registry URL:   $HAS_URL_INDEX"
log "npm install succeeds:            $([ $INSTALL_EXIT -eq 0 ] && echo 'YES' || echo 'NO')"
log ""

if [ "$ALL_MATCH" = "true" ]; then
  log "FINDING: The npm client pre-computes all integrity values (shasum + integrity)"
  log "and sends them with the tarball in a single PUT. The registry stores these"
  log "client-provided values directly — no server-side recomputation. The CDN"
  log "tarball is byte-for-byte what the client uploaded."
  log ""
  log "The race condition is entirely server-side: two clients each send a valid"
  log "tarball + matching hashes, and the registry fails to serialize the two"
  log "concurrent PUTs — resulting in one client's hashes in the packument with"
  log "the other client's tarball on the CDN."
fi

if [ "$CACHED_TARBALL_BLOB" = "true" ] && [ "$HAS_URL_INDEX" = "false" ]; then
  log ""
  log "CACHE NOTE: The published tarball IS cached as a content-addressed blob,"
  log "but without a URL-keyed index entry. npm install would not find it through"
  log "normal cache resolution. The publish cache does not appear to create a"
  log "persistence vector for the race condition."
fi
log ""
log "Result file: $RESULT_FILE"

rm -f "$CDN_TARBALL"
