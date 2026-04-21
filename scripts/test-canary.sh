#!/bin/bash
set -euo pipefail

echo "=== next@15.1.1-canary.0 integrity check ==="
echo ""

# Get manifest
MANIFEST=$(curl -s https://registry.npmjs.org/next/15.1.1-canary.0)
INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity')
SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum')
echo "Manifest integrity: $INTEGRITY"
echo "Manifest shasum:    $SHASUM"

# Download tarball
curl -sL https://registry.npmjs.org/next/-/next-15.1.1-canary.0.tgz -o /tmp/next-canary.tgz
ACTUAL_SHA1=$(shasum -a 1 /tmp/next-canary.tgz | cut -d' ' -f1)
ACTUAL_SHA512=$(shasum -a 512 /tmp/next-canary.tgz | cut -d' ' -f1)
echo "Tarball sha1:       $ACTUAL_SHA1"
echo "Tarball sha512:     ${ACTUAL_SHA512:0:40}..."

echo ""
if [ "$SHASUM" = "$ACTUAL_SHA1" ]; then
    echo "SHA-1: MATCH"
else
    echo "SHA-1: MISMATCH!"
    echo "  Manifest: $SHASUM"
    echo "  Actual:   $ACTUAL_SHA1"
fi

# Convert base64 sha512 from manifest to hex and compare
MANIFEST_HEX=$(echo "$INTEGRITY" | sed 's/sha512-//' | base64 -d 2>/dev/null | xxd -p | tr -d '\n')
if [ "$MANIFEST_HEX" = "$ACTUAL_SHA512" ]; then
    echo "SHA-512: MATCH"
else
    echo "SHA-512: MISMATCH!"
    echo "  Manifest: ${MANIFEST_HEX:0:40}..."
    echo "  Actual:   ${ACTUAL_SHA512:0:40}..."
fi

echo ""
echo "=== Tarball size ==="
ls -lh /tmp/next-canary.tgz | awk '{print $5}'
