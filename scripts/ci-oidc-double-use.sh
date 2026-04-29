#!/usr/bin/env bash
# ci-oidc-double-use.sh
#
# Tests whether a single OIDC-derived NAT can authorize TWO concurrent publishes
# of DIFFERENT versions. Different versions deliberately — if they both succeed,
# only the auth layer (not the publish-persistence layer's version-slot conflict)
# could have allowed it. That's a clean test of OIDC's single-use guarantee
# under concurrency.
#
# Inputs (positional):
#   $1  — npm auth token (NAT) obtained from a previous OIDC exchange (used as
#         fallback if ACTIONS_ID_TOKEN_REQUEST_URL is unset; in CI, fresh tokens
#         are minted per round).
#   $2  — round count (default 30). The race is probabilistic — likely needs
#         many rounds to either trigger or be confident it doesn't.
#
# Expected env (provided by GitHub Actions):
#   ACTIONS_ID_TOKEN_REQUEST_URL, ACTIONS_ID_TOKEN_REQUEST_TOKEN
#
# Output: per-round outcome line + final summary tally.
#
# Statistical note: the auth-layer race (if it exists) likely fires in a much
# narrower window than the manifest+CDN persistence race (~20% rate). The auth
# check is a single token-store read+write, not a multi-system propagation,
# so the window is milliseconds to tens of milliseconds. Likelier rates:
#
#   true rate 20%  →  P(0 bypasses in 15 rounds) =  3.5%   (very likely to trigger)
#   true rate 5%   →  P(0 bypasses in 15 rounds) = 46.3%   (need ~30 rounds)
#   true rate 1%   →  P(0 bypasses in 15 rounds) = 86%     (need ~100+ rounds)
#
# Default 30 rounds gives reasonable coverage if the rate is >=5%. For lower
# expected rates, run multiple invocations or override $2 to a higher value.
# A SINGLE bypass is the proof — even one observation across all rounds
# definitively answers the question.

set -euo pipefail

NAT_INPUT="${1:-}"
ROUNDS="${2:-30}"
PKG="ghostpublish"
REGISTRY="https://registry.npmjs.org"

if [ -z "$NAT_INPUT" ]; then
  echo "::error::Usage: $0 <oidc-derived-NAT> [rounds]" >&2
  exit 2
fi

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

build_tarball() {
  local version="$1" outdir="$2"
  rm -rf "$outdir"
  mkdir -p "$outdir/package"
  cat > "$outdir/package/package.json" <<EOF
{
  "name": "$PKG",
  "version": "$version",
  "license": "MIT",
  "description": "ci-oidc-double-use probe",
  "main": "index.js"
}
EOF
  echo "module.exports = { version: '$version', ts: '$(date +%s)' };" > "$outdir/package/index.js"
  ( cd "$outdir" && tar --no-xattrs --format=ustar -czf "package.tgz" package )
}

publish_with_nat() {
  local version="$1" outdir="$2" nat="$3" log_file="$4"

  local tgz="$outdir/package.tgz"
  local sha1 sha512_b64 integrity body_file
  sha1=$(shasum -a 1 "$tgz" 2>/dev/null | awk '{print $1}' || sha1sum "$tgz" | awk '{print $1}')
  sha512_b64=$(shasum -a 512 "$tgz" 2>/dev/null | awk '{print $1}' | xxd -r -p | base64 \
                 || sha512sum "$tgz" | awk '{print $1}' | xxd -r -p | base64)
  integrity="sha512-${sha512_b64}"

  body_file="$outdir/body.json"
  node -e "
    const fs = require('fs');
    const buf = fs.readFileSync('$tgz');
    const tgzName = '${PKG}-${version}.tgz';
    const body = {
      _id: '$PKG',
      name: '$PKG',
      description: 'ci-oidc-double-use probe',
      'dist-tags': { 'oidc-double-${version##*-}': '$version' },
      versions: {
        '$version': {
          name: '$PKG', version: '$version', license: 'MIT', main: 'index.js',
          _id: '${PKG}@${version}',
          dist: {
            tarball: '${REGISTRY}/${PKG}/-/' + tgzName,
            shasum: '$sha1',
            integrity: '$integrity',
          },
        },
      },
      _attachments: {
        [tgzName]: {
          content_type: 'application/octet-stream',
          data: buf.toString('base64'),
          length: buf.length,
        },
      },
    };
    fs.writeFileSync('$body_file', JSON.stringify(body));
  "

  local t0 t1
  t0=$(date +%s%3N)
  local http_code
  http_code=$(curl -s -o "$log_file" -w '%{http_code}' \
    -X PUT "${REGISTRY}/${PKG}" \
    -H "Authorization: Bearer ${nat}" \
    -H "Content-Type: application/json" \
    --data @"$body_file")
  t1=$(date +%s%3N)
  echo "$http_code $((t1 - t0))ms"
}

verify_version_exists() {
  local version="$1"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    "${REGISTRY}/${PKG}/${version}")
  echo "$code"
}

exchange_oidc_for_nat() {
  local oidc_id_token="$1"
  curl -s -X POST \
    "${REGISTRY}/-/npm/v1/oidc/token/exchange/package/${PKG}" \
    -H "Authorization: Bearer ${oidc_id_token}" \
    -H "Content-Type: application/json" \
    | jq -r '.token'
}

fetch_oidc_id_token() {
  curl -s \
    -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=npm:registry.npmjs.org" \
    | jq -r '.value'
}

# ----------------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------------

both_succeeded=0
one_succeeded=0
neither_succeeded=0
both_versions_landed=0

echo "ci-oidc-double-use: ${ROUNDS} round(s)"
echo

for ((r=1; r<=ROUNDS; r++)); do
  ts=$(date +%s)
  va="1.0.0-oidc-double-A-${ts}-r${r}"
  vb="1.0.0-oidc-double-B-${ts}-r${r}"

  # Per-round, fetch a fresh OIDC ID token and exchange. (Each round uses a
  # NEW NAT to ensure no carryover from prior rounds.) The CRITICAL part is
  # that within this round, the same NAT is used for both PUTs.
  if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
    oidc_id_token=$(fetch_oidc_id_token)
    if [ -z "$oidc_id_token" ] || [ "$oidc_id_token" = "null" ]; then
      echo "::error::Failed to fetch OIDC ID token in round $r"
      exit 1
    fi
    nat=$(exchange_oidc_for_nat "$oidc_id_token")
    if [ -z "$nat" ] || [ "$nat" = "null" ]; then
      echo "::error::Failed to exchange OIDC token in round $r"
      exit 1
    fi
  else
    # First round can use the NAT passed in; later rounds need fresh OIDC.
    nat="$NAT_INPUT"
  fi

  echo "=== Round $r ==="
  echo "  versions: $va, $vb"
  echo "  NAT: ...${nat: -8} (last 8 chars)"

  # Build both tarballs sequentially (cheap, no race needed here)
  outA=$(mktemp -d)
  outB=$(mktemp -d)
  build_tarball "$va" "$outA"
  build_tarball "$vb" "$outB"

  # Race the two publishes concurrently using the SAME NAT
  logA=$(mktemp)
  logB=$(mktemp)
  ( publish_with_nat "$va" "$outA" "$nat" "$logA" > "${outA}/result" ) &
  pid_a=$!
  ( publish_with_nat "$vb" "$outB" "$nat" "$logB" > "${outB}/result" ) &
  pid_b=$!
  wait "$pid_a" || true
  wait "$pid_b" || true

  result_a=$(cat "${outA}/result")
  result_b=$(cat "${outB}/result")
  http_a=${result_a%% *}
  http_b=${result_b%% *}

  echo "  PUT A ($va): HTTP $http_a"
  if [ "$http_a" != "200" ]; then echo "    body: $(cat $logA | head -c 200)"; fi
  echo "  PUT B ($vb): HTTP $http_b"
  if [ "$http_b" != "200" ]; then echo "    body: $(cat $logB | head -c 200)"; fi

  # Pause briefly, then verify
  sleep 3
  exists_a=$(verify_version_exists "$va")
  exists_b=$(verify_version_exists "$vb")
  echo "  Manifest GET A: $exists_a"
  echo "  Manifest GET B: $exists_b"

  if [ "$http_a" = "200" ] && [ "$http_b" = "200" ]; then
    both_succeeded=$((both_succeeded + 1))
    if [ "$exists_a" = "200" ] && [ "$exists_b" = "200" ]; then
      both_versions_landed=$((both_versions_landed + 1))
      echo "  *** BOTH VERSIONS LANDED — single-use BYPASSED ***"
    else
      echo "  Both PUTs returned 200 but only one version persisted (manifest async?)"
    fi
  elif [ "$http_a" = "200" ] || [ "$http_b" = "200" ]; then
    one_succeeded=$((one_succeeded + 1))
    echo "  Single-use enforced (one passed, one rejected)"
  else
    neither_succeeded=$((neither_succeeded + 1))
    echo "  Neither succeeded"
  fi
  echo
done

echo '=== SUMMARY ==='
echo "Total rounds:           $ROUNDS"
echo "Both PUTs HTTP 200:     $both_succeeded"
echo "One PUT 200, one not:   $one_succeeded"
echo "Neither succeeded:      $neither_succeeded"
echo "Both versions landed:   $both_versions_landed (definitive single-use bypass)"
