#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results"

PKG="ghostpublish"

VERSION="${1:-}"
if [ -z "$VERSION" ] && [ -f "$RESULTS_DIR/last-race-version.txt" ]; then
    VERSION=$(cat "$RESULTS_DIR/last-race-version.txt")
fi
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/cache-poison-$(date +%Y%m%d-%H%M%S).log"

log() { echo "$@" | tee -a "$RESULT_FILE"; }

log "=== Cache / CI persistence test ==="
log "Package: $PKG@$VERSION"
log "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log ""

TARBALL_URL="https://registry.npmjs.org/$PKG/-/$PKG-$VERSION.tgz"
curl -sL "$TARBALL_URL" -o /tmp/ghost-tarball.tgz
TARBALL_SHA1=$(shasum -a 1 /tmp/ghost-tarball.tgz | cut -d' ' -f1)
TARBALL_INTEGRITY="sha512-$(shasum -a 512 -b /tmp/ghost-tarball.tgz | cut -d' ' -f1 | xxd -r -p | base64)"

MANIFEST=$(curl -s "https://registry.npmjs.org/$PKG/$VERSION")
MANIFEST_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum')
MANIFEST_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity')

log "Manifest dist.shasum:    $MANIFEST_SHASUM"
log "Manifest dist.integrity: $MANIFEST_INTEGRITY"
log "Tarball sha1:            $TARBALL_SHA1"
log "Tarball integrity:       $TARBALL_INTEGRITY"
log ""

if [ "$MANIFEST_SHASUM" = "$TARBALL_SHA1" ]; then
    log "No mismatch detected."
    log ""
fi

log "=== Scenario 1: Warm npm cache + --prefer-offline ==="
log ""

npm cache clean --force 2>/dev/null || true

log "Seeding npm cache..."
npm cache add "$TARBALL_URL" 2>&1 | tee -a "$RESULT_FILE" || true
log ""

log "npm install --prefer-offline"
rm -rf /tmp/ghost-cache-test1 && mkdir -p /tmp/ghost-cache-test1
CACHE_EXIT1=0
(
    cd /tmp/ghost-cache-test1
    echo '{"name":"cache-test","version":"1.0.0","private":true}' > package.json
    npm install "$PKG@$VERSION" --prefer-offline 2>&1
) && CACHE_EXIT1=0 || CACHE_EXIT1=$?
log "Exit: $CACHE_EXIT1"
if [ $CACHE_EXIT1 -eq 0 ]; then
    log "INSTALLED"
    log "  content: $(cat /tmp/ghost-cache-test1/node_modules/$PKG/index.js 2>/dev/null || echo 'N/A')"
else
    log "REJECTED"
fi
log ""

log "=== Scenario 2: Pre-existing node_modules ==="
log ""

rm -rf /tmp/ghost-cache-test2 && mkdir -p /tmp/ghost-cache-test2/node_modules/$PKG
mkdir -p /tmp/ghost-cache-extract && tar xzf /tmp/ghost-tarball.tgz -C /tmp/ghost-cache-extract 2>/dev/null || true
cp -r /tmp/ghost-cache-extract/package/* /tmp/ghost-cache-test2/node_modules/$PKG/

cat > /tmp/ghost-cache-test2/package.json << EOF
{"name":"cache-test","version":"1.0.0","private":true,"dependencies":{"$PKG":"$VERSION"}}
EOF

cat > /tmp/ghost-cache-test2/package-lock.json << EOF
{
  "name": "cache-test",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "cache-test",
      "version": "1.0.0",
      "dependencies": {
        "$PKG": "$VERSION"
      }
    },
    "node_modules/$PKG": {
      "version": "$VERSION",
      "resolved": "$TARBALL_URL",
      "integrity": "$TARBALL_INTEGRITY"
    }
  }
}
EOF
log "Lockfile integrity: $TARBALL_INTEGRITY"
log ""

log "2a: npm ci"
CACHE_EXIT2A=0
(
    cd /tmp/ghost-cache-test2
    npm ci 2>&1
) && CACHE_EXIT2A=0 || CACHE_EXIT2A=$?
log "Exit: $CACHE_EXIT2A"
if [ $CACHE_EXIT2A -eq 0 ]; then
    log "npm ci: INSTALLED"
    log "  content: $(cat /tmp/ghost-cache-test2/node_modules/$PKG/index.js 2>/dev/null || echo 'N/A')"
else
    log "npm ci: REJECTED"
fi
log ""

log "2b: npm install (with existing node_modules)"
rm -rf /tmp/ghost-cache-test2/node_modules
mkdir -p /tmp/ghost-cache-test2/node_modules/$PKG
cp -r /tmp/ghost-cache-extract/package/* /tmp/ghost-cache-test2/node_modules/$PKG/
CACHE_EXIT2B=0
(
    cd /tmp/ghost-cache-test2
    npm install 2>&1
) && CACHE_EXIT2B=0 || CACHE_EXIT2B=$?
log "Exit: $CACHE_EXIT2B"
if [ $CACHE_EXIT2B -eq 0 ]; then
    log "npm install: INSTALLED"
    log "  content: $(cat /tmp/ghost-cache-test2/node_modules/$PKG/index.js 2>/dev/null || echo 'N/A')"
else
    log "npm install: REJECTED"
fi
log ""

log "=== Scenario 3: Lockfile has manifest integrity ==="
log ""

rm -rf /tmp/ghost-cache-test3 && mkdir -p /tmp/ghost-cache-test3
cat > /tmp/ghost-cache-test3/package.json << EOF
{"name":"cache-test","version":"1.0.0","private":true,"dependencies":{"$PKG":"$VERSION"}}
EOF
cat > /tmp/ghost-cache-test3/package-lock.json << EOF
{
  "name": "cache-test",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "cache-test",
      "version": "1.0.0",
      "dependencies": {
        "$PKG": "$VERSION"
      }
    },
    "node_modules/$PKG": {
      "version": "$VERSION",
      "resolved": "$TARBALL_URL",
      "integrity": "$MANIFEST_INTEGRITY"
    }
  }
}
EOF
log "Lockfile integrity: $MANIFEST_INTEGRITY"
log "CDN tarball integrity: $TARBALL_INTEGRITY"
log ""

npm cache clean --force 2>/dev/null || true
CACHE_EXIT3=0
(
    cd /tmp/ghost-cache-test3
    npm ci 2>&1
) && CACHE_EXIT3=0 || CACHE_EXIT3=$?
log "Exit: $CACHE_EXIT3"
if [ $CACHE_EXIT3 -eq 0 ]; then
    log "npm ci: INSTALLED"
    log "  content: $(cat /tmp/ghost-cache-test3/node_modules/$PKG/index.js 2>/dev/null || echo 'N/A')"
else
    log "npm ci: REJECTED"
fi
log ""

log "=== Results ==="
log ""
log "Scenario 1 (warm cache + --prefer-offline):       $([ $CACHE_EXIT1 -eq 0 ] && echo 'INSTALLED' || echo 'REJECTED')"
log "Scenario 2a (npm ci + lockfile w/ tarball hash):   $([ $CACHE_EXIT2A -eq 0 ] && echo 'INSTALLED' || echo 'REJECTED')"
log "Scenario 2b (npm install + existing node_modules): $([ $CACHE_EXIT2B -eq 0 ] && echo 'INSTALLED' || echo 'REJECTED')"
log "Scenario 3 (npm ci + lockfile w/ manifest hash):   $([ $CACHE_EXIT3 -eq 0 ] && echo 'INSTALLED' || echo 'REJECTED')"
log ""
log "Result file: $RESULT_FILE"
