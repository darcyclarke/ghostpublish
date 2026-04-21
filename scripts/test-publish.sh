#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NPMRC="$PROJECT_DIR/.npmrc"
RESULTS_DIR="$PROJECT_DIR/results"

PKG="ghostpublish"
VERSION="1.0.0-race.$(date +%s)"
ATTEMPT=${1:-1}
MAX_ATTEMPTS=${2:-5}

mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/race-$(date +%Y%m%d-%H%M%S).log"

log() { echo "$@" | tee -a "$RESULT_FILE"; }

log "=== Concurrent publish test ==="
log "Package: $PKG@$VERSION"
log "Attempt: $ATTEMPT of $MAX_ATTEMPTS"
log "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log ""

# Create tarball A
rm -rf /tmp/ghost-tarball-a && mkdir -p /tmp/ghost-tarball-a
cat > /tmp/ghost-tarball-a/package.json << EOF
{"name": "$PKG", "version": "$VERSION", "description": "variant A"}
EOF
echo "// TARBALL-A: $(openssl rand -hex 16)" > /tmp/ghost-tarball-a/index.js
cp "$NPMRC" /tmp/ghost-tarball-a/.npmrc

rm -rf /tmp/ghost-tarball-b && mkdir -p /tmp/ghost-tarball-b
cat > /tmp/ghost-tarball-b/package.json << EOF
{"name": "$PKG", "version": "$VERSION", "description": "variant B"}
EOF
echo "// TARBALL-B: $(openssl rand -hex 16)" > /tmp/ghost-tarball-b/index.js
cp "$NPMRC" /tmp/ghost-tarball-b/.npmrc

log "Tarball A content: $(cat /tmp/ghost-tarball-a/index.js)"
log "Tarball B content: $(cat /tmp/ghost-tarball-b/index.js)"
log ""

# Pre-compute integrity values
A_INTEGRITY=$(cd /tmp/ghost-tarball-a && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
B_INTEGRITY=$(cd /tmp/ghost-tarball-b && npm pack --json 2>/dev/null | jq -r '.[0].integrity')
log "A integrity (pre-publish): $A_INTEGRITY"
log "B integrity (pre-publish): $B_INTEGRITY"
log ""

# Clean up .tgz files from npm pack
rm -f /tmp/ghost-tarball-a/*.tgz /tmp/ghost-tarball-b/*.tgz

log "=== Racing two publishes ==="
(cd /tmp/ghost-tarball-a && npm publish --access public --tag race 2>&1 | tee /tmp/ghost-publish-a.log) &
PID_A=$!
(cd /tmp/ghost-tarball-b && npm publish --access public --tag race 2>&1 | tee /tmp/ghost-publish-b.log) &
PID_B=$!

set +e
wait $PID_A; EXIT_A=$?
wait $PID_B; EXIT_B=$?
set -e

log ""
log "Publish A exit code: $EXIT_A"
log "Publish B exit code: $EXIT_B"
log ""
log "--- Publish A output ---"
cat /tmp/ghost-publish-a.log >> "$RESULT_FILE"
cat /tmp/ghost-publish-a.log
log ""
log "--- Publish B output ---"
cat /tmp/ghost-publish-b.log >> "$RESULT_FILE"
cat /tmp/ghost-publish-b.log
log ""

# Detect success by exit code 0
A_SUCCESS=0
B_SUCCESS=0
[ $EXIT_A -eq 0 ] && A_SUCCESS=1
[ $EXIT_B -eq 0 ] && B_SUCCESS=1

if [ "$A_SUCCESS" -eq 1 ] && [ "$B_SUCCESS" -eq 1 ]; then
    log ""
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "!! BOTH PUBLISHES SUCCEEDED !!"
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log ""
else
    log ""
    if [ "$A_SUCCESS" -eq 1 ] || [ "$B_SUCCESS" -eq 1 ]; then
        log "One publish succeeded, one failed."
    else
        log "Both publishes failed."
    fi
    log ""
fi

# Skip manifest check if neither publish succeeded
if [ "$A_SUCCESS" -eq 0 ] && [ "$B_SUCCESS" -eq 0 ]; then
    log "Both publishes failed — skipping manifest/tarball check."
    echo "$VERSION" > "$RESULTS_DIR/last-race-version.txt"

    if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
        NEXT=$((ATTEMPT + 1))
        log ""
        log "Retrying... (attempt $NEXT of $MAX_ATTEMPTS)"
        sleep 2
        exec "$0" "$NEXT" "$MAX_ATTEMPTS"
    else
        log ""
        log "Done after $MAX_ATTEMPTS attempts."
        log "Try again or increase MAX_ATTEMPTS: $0 1 10"
        exit 1
    fi
fi

# Wait for CDN propagation
log "Waiting 10 seconds for CDN propagation..."
sleep 10

# Fetch manifest
log ""
log "=== Checking manifest vs tarball integrity ==="
MANIFEST=$(curl -s "https://registry.npmjs.org/$PKG/$VERSION")
MANIFEST_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // "null"')
MANIFEST_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // "null"')
log "Manifest integrity: $MANIFEST_INTEGRITY"
log "Manifest shasum:    $MANIFEST_SHASUM"

if [ "$MANIFEST_SHASUM" = "null" ]; then
    log ""
    log "Version not found in registry (both publishes may have failed)."
    log "Result file: $RESULT_FILE"
    exit 1
fi

# Download actual tarball
TARBALL_URL="https://registry.npmjs.org/$PKG/-/$PKG-$VERSION.tgz"
curl -sL "$TARBALL_URL" -o /tmp/ghost-downloaded.tgz
ACTUAL_SHA1=$(shasum -a 1 /tmp/ghost-downloaded.tgz | cut -d' ' -f1)
ACTUAL_INTEGRITY="sha512-$(shasum -a 512 -b /tmp/ghost-downloaded.tgz | cut -d' ' -f1 | xxd -r -p | base64)"
log "Tarball sha1:       $ACTUAL_SHA1"
log "Tarball integrity:  $ACTUAL_INTEGRITY"

log ""
if [ "$MANIFEST_SHASUM" = "$ACTUAL_SHA1" ]; then
    log "SHA-1 (dist.shasum): MATCH"
else
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "!! SHA-1 MISMATCH !!"
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "   Manifest dist.shasum: $MANIFEST_SHASUM"
    log "   Actual tarball sha1:  $ACTUAL_SHA1"
fi

if [ "$MANIFEST_INTEGRITY" = "$ACTUAL_INTEGRITY" ]; then
    log "SHA-512 (dist.integrity): MATCH"
else
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "!! SHA-512 MISMATCH !!"
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "   Manifest dist.integrity: $MANIFEST_INTEGRITY"
    log "   Actual tarball sha512:   $ACTUAL_INTEGRITY"
fi

# Extract and show tarball contents
log ""
log "=== Tarball content ==="
mkdir -p /tmp/ghost-extract && rm -rf /tmp/ghost-extract/*
tar xzf /tmp/ghost-downloaded.tgz -C /tmp/ghost-extract
log "index.js: $(cat /tmp/ghost-extract/package/index.js)"
log "description: $(jq -r .description /tmp/ghost-extract/package/package.json)"

# Compare which tarball won
TARBALL_CONTENT=$(cat /tmp/ghost-extract/package/index.js)
if echo "$TARBALL_CONTENT" | grep -q "TARBALL-A"; then
    log "Winner: Tarball A"
elif echo "$TARBALL_CONTENT" | grep -q "TARBALL-B"; then
    log "Winner: Tarball B"
fi

log ""
log "=== Summary ==="
log "Version:         $VERSION"
log "Both succeeded:  $([ "$A_SUCCESS" -eq 1 ] && [ "$B_SUCCESS" -eq 1 ] && echo 'YES' || echo 'NO')"
log "SHA-1 match:     $([ "$MANIFEST_SHASUM" = "$ACTUAL_SHA1" ] && echo 'YES' || echo 'NO (MISMATCH!)')"
log "SHA-512 match:   $([ "$MANIFEST_INTEGRITY" = "$ACTUAL_INTEGRITY" ] && echo 'YES' || echo 'NO (MISMATCH!)')"
log "Result file:     $RESULT_FILE"

# Save version for subsequent tests
echo "$VERSION" > "$RESULTS_DIR/last-race-version.txt"
log ""
log "Saved version to $RESULTS_DIR/last-race-version.txt for use with other tests."

# Auto-retry logic
if [ "$A_SUCCESS" -eq 1 ] && [ "$B_SUCCESS" -eq 1 ]; then
    exit 0
else
    if [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
        NEXT=$((ATTEMPT + 1))
        log ""
        log "Retrying... (attempt $NEXT of $MAX_ATTEMPTS)"
        sleep 2
        exec "$0" "$NEXT" "$MAX_ATTEMPTS"
    else
        log ""
        log "Done after $MAX_ATTEMPTS attempts."
        log "Try again or increase MAX_ATTEMPTS: $0 1 10"
        exit 1
    fi
fi
