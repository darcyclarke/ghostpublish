#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results"

PKG="ghostpublish"

# Accept version as arg or read from last race result
VERSION="${1:-}"
if [ -z "$VERSION" ] && [ -f "$RESULTS_DIR/last-race-version.txt" ]; then
    VERSION=$(cat "$RESULTS_DIR/last-race-version.txt")
fi
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "   or run test:race first to auto-populate the version"
    exit 1
fi

echo "=== Package manager install test ==="
echo "Package: $PKG@$VERSION"
echo ""

# Verify mismatch exists
MANIFEST=$(curl -s "https://registry.npmjs.org/$PKG/$VERSION")
MANIFEST_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum')
MANIFEST_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity')
TARBALL_URL="https://registry.npmjs.org/$PKG/-/$PKG-$VERSION.tgz"
curl -sL "$TARBALL_URL" -o /tmp/ghost-check.tgz
ACTUAL_SHA1=$(shasum -a 1 /tmp/ghost-check.tgz | cut -d' ' -f1)
ACTUAL_INTEGRITY="sha512-$(shasum -a 512 -b /tmp/ghost-check.tgz | cut -d' ' -f1 | xxd -r -p | base64)"

echo "Manifest dist.shasum:    $MANIFEST_SHASUM"
echo "Tarball sha1:            $ACTUAL_SHA1"
echo "Manifest dist.integrity: $MANIFEST_INTEGRITY"
echo "Tarball integrity:       $ACTUAL_INTEGRITY"
echo ""

MISMATCH=false
if [ "$MANIFEST_SHASUM" != "$ACTUAL_SHA1" ]; then
    echo "SHA-1 mismatch confirmed!"
    MISMATCH=true
fi
if [ "$MANIFEST_INTEGRITY" != "$ACTUAL_INTEGRITY" ]; then
    echo "SHA-512 (dist.integrity) mismatch confirmed!"
    MISMATCH=true
fi
if [ "$MISMATCH" = "false" ]; then
    echo "No mismatch detected."
fi
echo ""

NPM_EXIT=0
YARN_EXIT=0
PNPM_EXIT=0
BUN_EXIT=0
DENO_EXIT=0
VLT_EXIT=0

# Test npm
echo "=== npm ==="
npm cache clean --force 2>/dev/null || true
rm -rf /tmp/ghost-test-npm && mkdir -p /tmp/ghost-test-npm
(
    cd /tmp/ghost-test-npm
    echo '{"name":"ghost-integrity-test","version":"1.0.0","private":true}' > package.json
    npm install "$PKG@$VERSION" 2>&1
) && NPM_EXIT=0 || NPM_EXIT=$?
echo "npm exit: $NPM_EXIT"
if [ $NPM_EXIT -eq 0 ]; then
    echo "npm result: INSTALLED"
    echo "  content: $(cat /tmp/ghost-test-npm/node_modules/$PKG/index.js 2>/dev/null || echo 'N/A')"
else
    echo "npm result: REJECTED"
fi
echo ""

# Test yarn (if available)
if command -v yarn &>/dev/null; then
    echo "=== yarn ==="
    yarn cache clean 2>/dev/null || true
    rm -rf /tmp/ghost-test-yarn && mkdir -p /tmp/ghost-test-yarn
    (
        cd /tmp/ghost-test-yarn
        echo '{"name":"ghost-integrity-test","version":"1.0.0","private":true}' > package.json
        yarn add "$PKG@$VERSION" 2>&1
    ) && YARN_EXIT=0 || YARN_EXIT=$?
    echo "yarn exit: $YARN_EXIT"
    echo ""
else
    echo "=== yarn === (not installed, skipping)"
    YARN_EXIT=-1
    echo ""
fi

# Test pnpm (if available)
if command -v pnpm &>/dev/null; then
    echo "=== pnpm ==="
    pnpm store prune 2>/dev/null || true
    rm -rf /tmp/ghost-test-pnpm && mkdir -p /tmp/ghost-test-pnpm
    (
        cd /tmp/ghost-test-pnpm
        echo '{"name":"ghost-integrity-test","version":"1.0.0","private":true}' > package.json
        pnpm add "$PKG@$VERSION" 2>&1
    ) && PNPM_EXIT=0 || PNPM_EXIT=$?
    echo "pnpm exit: $PNPM_EXIT"
    echo ""
else
    echo "=== pnpm === (not installed, skipping)"
    PNPM_EXIT=-1
    echo ""
fi

# Test bun (if available)
if command -v bun &>/dev/null; then
    echo "=== bun ==="
    rm -rf /tmp/ghost-test-bun && mkdir -p /tmp/ghost-test-bun
    (
        cd /tmp/ghost-test-bun
        echo '{"name":"ghost-integrity-test","version":"1.0.0","private":true}' > package.json
        bun add "$PKG@$VERSION" 2>&1
    ) && BUN_EXIT=0 || BUN_EXIT=$?
    echo "bun exit: $BUN_EXIT"
    echo ""
else
    echo "=== bun === (not installed, skipping)"
    BUN_EXIT=-1
    echo ""
fi

# Test deno (if available)
if command -v deno &>/dev/null; then
    echo "=== deno ==="
    rm -rf /tmp/ghost-test-deno && mkdir -p /tmp/ghost-test-deno
    (
        cd /tmp/ghost-test-deno
        echo '{"name":"ghost-integrity-test","version":"1.0.0","private":true}' > package.json
        deno install "npm:$PKG@$VERSION" 2>&1
    ) && DENO_EXIT=0 || DENO_EXIT=$?
    echo "deno exit: $DENO_EXIT"
    echo ""
else
    echo "=== deno === (not installed, skipping)"
    DENO_EXIT=-1
    echo ""
fi

# Test vlt (if available)
if command -v vlt &>/dev/null; then
    echo "=== vlt ==="
    rm -rf /tmp/ghost-test-vlt && mkdir -p /tmp/ghost-test-vlt
    (
        cd /tmp/ghost-test-vlt
        echo '{"name":"ghost-integrity-test","version":"1.0.0","private":true}' > package.json
        vlt install "$PKG@$VERSION" 2>&1
    ) && VLT_EXIT=0 || VLT_EXIT=$?
    echo "vlt exit: $VLT_EXIT"
    echo ""
else
    echo "=== vlt === (not installed, skipping)"
    VLT_EXIT=-1
    echo ""
fi

# Summary
echo "=== RESULTS ==="
echo "Mismatch present: $MISMATCH"
echo ""

status() {
    local code=$1 name=$2
    if [ "$code" -eq -1 ]; then
        echo "$name: SKIPPED (not installed)"
    elif [ "$code" -eq 0 ]; then
        echo "$name: INSTALLED"
    else
        echo "$name: REJECTED"
    fi
}

status $NPM_EXIT "npm"
status $YARN_EXIT "yarn"
status $PNPM_EXIT "pnpm"
status $BUN_EXIT "bun"
status $DENO_EXIT "deno"
status $VLT_EXIT "vlt"
