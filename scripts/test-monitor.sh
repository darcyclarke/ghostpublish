#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results"

PKG="ghostpublish"
POLL_INTERVAL="${2:-30}"

# Accept version as arg or read from last race result
VERSION="${1:-}"
if [ -z "$VERSION" ] && [ -f "$RESULTS_DIR/last-race-version.txt" ]; then
    VERSION=$(cat "$RESULTS_DIR/last-race-version.txt")
fi
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [poll_interval_seconds]"
    echo "   or run test:race first to auto-populate the version"
    exit 1
fi

mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/self-heal-$(date +%Y%m%d-%H%M%S).log"

log() { echo "$@" | tee -a "$RESULT_FILE"; }

log "=== Registry consistency monitor ==="
log "Package: $PKG@$VERSION"
log "Poll interval: ${POLL_INTERVAL}s"
log "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Press Ctrl+C to stop"
log ""

PREV_INTEGRITY=""
STARTED_AT=$(date +%s)

while true; do
    MANIFEST=$(curl -s "https://registry.npmjs.org/$PKG/$VERSION")
    INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // "null"')
    SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // "null"')

    TARBALL_URL="https://registry.npmjs.org/$PKG/-/$PKG-$VERSION.tgz"
    curl -sL "$TARBALL_URL" -o /tmp/ghost-monitor.tgz
    ACTUAL_SHA1=$(shasum -a 1 /tmp/ghost-monitor.tgz | cut -d' ' -f1)
    ACTUAL_INTEGRITY="sha512-$(shasum -a 512 -b /tmp/ghost-monitor.tgz | cut -d' ' -f1 | xxd -r -p | base64)"

    ELAPSED=$(( $(date +%s) - STARTED_AT ))
    ELAPSED_MIN=$(( ELAPSED / 60 ))

    if [ "$INTEGRITY" != "$PREV_INTEGRITY" ] && [ -n "$PREV_INTEGRITY" ]; then
        log "[$(date -u +%H:%M:%S)] (+${ELAPSED_MIN}m) dist.integrity CHANGED!"
        log "  Old: $PREV_INTEGRITY"
        log "  New: $INTEGRITY"
    fi
    PREV_INTEGRITY="$INTEGRITY"

    SHA1_OK=false
    SHA512_OK=false
    [ "$SHASUM" = "$ACTUAL_SHA1" ] && SHA1_OK=true
    [ "$INTEGRITY" = "$ACTUAL_INTEGRITY" ] && SHA512_OK=true

    if [ "$SHA1_OK" = "true" ] && [ "$SHA512_OK" = "true" ]; then
        log "[$(date -u +%H:%M:%S)] (+${ELAPSED_MIN}m) MATCH — both sha1 and sha512 consistent"
        log "  dist.shasum:    $SHASUM"
        log "  dist.integrity: $INTEGRITY"

        if [ $ELAPSED -gt 10 ]; then
            log ""
            log "=== Consistent ==="
            log "Elapsed: ~${ELAPSED_MIN} minutes (${ELAPSED}s)"
            log "Result file: $RESULT_FILE"
            break
        else
            log "  (initial check, continuing to monitor)"
        fi
    else
        log "[$(date -u +%H:%M:%S)] (+${ELAPSED_MIN}m) MISMATCH"
        [ "$SHA1_OK" = "false" ] && log "  sha1:   manifest=$SHASUM tarball=$ACTUAL_SHA1"
        [ "$SHA512_OK" = "false" ] && log "  sha512: manifest=$INTEGRITY"
        [ "$SHA512_OK" = "false" ] && log "         tarball=$ACTUAL_INTEGRITY"
    fi

    sleep "$POLL_INTERVAL"
done
