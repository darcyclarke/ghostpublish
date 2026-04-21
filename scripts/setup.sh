#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NPMRC="$PROJECT_DIR/.npmrc"

echo "=== Setup ==="
echo ""

if [ ! -f "$NPMRC" ]; then
    echo "Missing .npmrc at $NPMRC"
    exit 1
fi
echo ".npmrc found"

WHOAMI=$(npm --userconfig "$NPMRC" whoami 2>/dev/null || true)
if [ -z "$WHOAMI" ]; then
    echo "npm auth failed"
    exit 1
fi
echo "Authenticated as: $WHOAMI"

MISSING=()
for cmd in curl jq shasum node npm; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING+=("$cmd")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Missing tools: ${MISSING[*]}"
    exit 1
fi
echo "Tools: ok (node $(node --version) / npm $(npm --version))"

TOKEN=$(grep authToken "$NPMRC" | cut -d= -f2)
echo ""
curl -s "https://registry.npmjs.org/-/npm/v1/tokens" \
    -H "Authorization: Bearer $TOKEN" | jq '.objects[] | {key, cidr_whitelist, readonly, automation, created}' 2>/dev/null || true

echo ""
echo "=== Ready ==="
echo "  vlr test:publish"
echo "  vlr test:install"
echo "  vlr test:monitor"
echo "  vlr test:provenance"
echo "  vlr test:canary"
echo "  vlr test:cache"
