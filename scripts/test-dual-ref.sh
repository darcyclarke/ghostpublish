#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results"

PKG="ghostpublish"
WORKFLOW="test-dual-ref.yml"
TIMESTAMP=$(date +%s)
VERSION="1.0.0-dualref.${TIMESTAMP}"
BRANCH_A="dual-ref-a-${TIMESTAMP}"
BRANCH_B="dual-ref-b-${TIMESTAMP}"

ROUNDS="${1:-3}"

mkdir -p "$RESULTS_DIR"
RESULT_FILE="$RESULTS_DIR/dual-ref-$(date +%Y%m%d-%H%M%S).log"

log() { echo "$@" | tee -a "$RESULT_FILE"; }

log "=== Dual-Ref Provenance Race Test ==="
log "Scenario: Two separate CI runs from different git refs, both publishing"
log "the same version with OIDC provenance — the next@15.1.1-canary.0 scenario."
log ""
log "Package:  $PKG"
log "Rounds:   $ROUNDS"
log "Workflow: $WORKFLOW"
log ""

CURRENT_BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)
log "Current branch: $CURRENT_BRANCH"
log ""

log "[1] Ensuring workflow exists on remote..."

if ! git -C "$PROJECT_DIR" diff --quiet HEAD -- ".github/workflows/$WORKFLOW" 2>/dev/null; then
  log "  Workflow has uncommitted changes — committing first..."
  git -C "$PROJECT_DIR" add ".github/workflows/$WORKFLOW"
  git -C "$PROJECT_DIR" commit -m "add dual-ref provenance test workflow" || true
fi

git -C "$PROJECT_DIR" push origin "$CURRENT_BRANCH" 2>&1 | tee -a "$RESULT_FILE"
log ""

CLEANUP_BRANCHES=()
trap 'cleanup' EXIT

cleanup() {
  log ""
  log "Cleaning up branches..."
  for BRANCH in "${CLEANUP_BRANCHES[@]}"; do
    git -C "$PROJECT_DIR" branch -D "$BRANCH" 2>/dev/null || true
    git -C "$PROJECT_DIR" push origin --delete "$BRANCH" 2>/dev/null || true
    log "  deleted: $BRANCH"
  done
  git -C "$PROJECT_DIR" checkout "$CURRENT_BRANCH" 2>/dev/null || true
}

for ROUND in $(seq 1 "$ROUNDS"); do
  ROUND_VERSION="${VERSION}.r${ROUND}"
  ROUND_BRANCH_A="${BRANCH_A}-r${ROUND}"
  ROUND_BRANCH_B="${BRANCH_B}-r${ROUND}"

  log ""
  log "=========================================="
  log "Round $ROUND/$ROUNDS — $ROUND_VERSION"
  log "=========================================="
  log ""

  log "[2] Creating divergent branches..."

  git -C "$PROJECT_DIR" checkout -b "$ROUND_BRANCH_A" "$CURRENT_BRANCH" 2>/dev/null
  echo "// branch A variant — round $ROUND — $(date +%s%N)" > "$PROJECT_DIR/variant.txt"
  git -C "$PROJECT_DIR" add variant.txt
  git -C "$PROJECT_DIR" commit -m "dual-ref test: variant A round $ROUND" --allow-empty 2>/dev/null
  git -C "$PROJECT_DIR" push origin "$ROUND_BRANCH_A" 2>&1 | tee -a "$RESULT_FILE"
  SHA_A=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  log "  Branch A: $ROUND_BRANCH_A ($SHA_A)"
  CLEANUP_BRANCHES+=("$ROUND_BRANCH_A")

  git -C "$PROJECT_DIR" checkout "$CURRENT_BRANCH" 2>/dev/null
  git -C "$PROJECT_DIR" checkout -b "$ROUND_BRANCH_B" "$CURRENT_BRANCH" 2>/dev/null
  echo "// branch B variant — round $ROUND — $(date +%s%N)" > "$PROJECT_DIR/variant.txt"
  git -C "$PROJECT_DIR" add variant.txt
  git -C "$PROJECT_DIR" commit -m "dual-ref test: variant B round $ROUND" --allow-empty 2>/dev/null
  git -C "$PROJECT_DIR" push origin "$ROUND_BRANCH_B" 2>&1 | tee -a "$RESULT_FILE"
  SHA_B=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  log "  Branch B: $ROUND_BRANCH_B ($SHA_B)"
  CLEANUP_BRANCHES+=("$ROUND_BRANCH_B")

  git -C "$PROJECT_DIR" checkout "$CURRENT_BRANCH" 2>/dev/null
  log ""

  log "[3] Triggering both workflows simultaneously..."
  log "  Version: $ROUND_VERSION"
  log "  Ref A:   $ROUND_BRANCH_A"
  log "  Ref B:   $ROUND_BRANCH_B"

  gh workflow run "$WORKFLOW" \
    --ref "$ROUND_BRANCH_A" \
    -f version="$ROUND_VERSION" \
    -f variant="A" \
    -R darcyclarke/ghostpublish 2>&1 | tee -a "$RESULT_FILE" &
  PID_DISPATCH_A=$!

  gh workflow run "$WORKFLOW" \
    --ref "$ROUND_BRANCH_B" \
    -f version="$ROUND_VERSION" \
    -f variant="B" \
    -R darcyclarke/ghostpublish 2>&1 | tee -a "$RESULT_FILE" &
  PID_DISPATCH_B=$!

  wait $PID_DISPATCH_A || true
  wait $PID_DISPATCH_B || true
  log "  Both dispatched"
  log ""

  log "[4] Waiting for runs to appear..."
  sleep 10

  RUNS=$(gh run list --workflow="$WORKFLOW" --limit=10 --json databaseId,headBranch,status,conclusion \
    -R darcyclarke/ghostpublish 2>/dev/null)

  RUN_A=$(echo "$RUNS" | jq -r "[.[] | select(.headBranch==\"$ROUND_BRANCH_A\")] | .[0].databaseId // empty")
  RUN_B=$(echo "$RUNS" | jq -r "[.[] | select(.headBranch==\"$ROUND_BRANCH_B\")] | .[0].databaseId // empty")

  if [ -z "$RUN_A" ] || [ -z "$RUN_B" ]; then
    log "  WARNING: Could not find both runs. A=$RUN_A B=$RUN_B"
    log "  Retrying lookup in 15s..."
    sleep 15
    RUNS=$(gh run list --workflow="$WORKFLOW" --limit=10 --json databaseId,headBranch,status,conclusion \
      -R darcyclarke/ghostpublish 2>/dev/null)
    RUN_A=$(echo "$RUNS" | jq -r "[.[] | select(.headBranch==\"$ROUND_BRANCH_A\")] | .[0].databaseId // empty")
    RUN_B=$(echo "$RUNS" | jq -r "[.[] | select(.headBranch==\"$ROUND_BRANCH_B\")] | .[0].databaseId // empty")
  fi

  log "  Run A: $RUN_A (branch: $ROUND_BRANCH_A)"
  log "  Run B: $RUN_B (branch: $ROUND_BRANCH_B)"
  log ""

  log "[5] Monitoring runs to completion..."

  DONE_A=false
  DONE_B=false
  CONCLUSION_A=""
  CONCLUSION_B=""

  for i in $(seq 1 60); do
    if [ "$DONE_A" = "false" ] && [ -n "$RUN_A" ]; then
      STATUS_A=$(gh run view "$RUN_A" --json status,conclusion -R darcyclarke/ghostpublish 2>/dev/null | jq -r '.status')
      if [ "$STATUS_A" = "completed" ]; then
        CONCLUSION_A=$(gh run view "$RUN_A" --json conclusion -R darcyclarke/ghostpublish 2>/dev/null | jq -r '.conclusion')
        DONE_A=true
      fi
    fi

    if [ "$DONE_B" = "false" ] && [ -n "$RUN_B" ]; then
      STATUS_B=$(gh run view "$RUN_B" --json status,conclusion -R darcyclarke/ghostpublish 2>/dev/null | jq -r '.status')
      if [ "$STATUS_B" = "completed" ]; then
        CONCLUSION_B=$(gh run view "$RUN_B" --json conclusion -R darcyclarke/ghostpublish 2>/dev/null | jq -r '.conclusion')
        DONE_B=true
      fi
    fi

    if [ "$DONE_A" = "true" ] && [ "$DONE_B" = "true" ]; then
      break
    fi

    echo "  ... waiting (A=${STATUS_A:-pending} B=${STATUS_B:-pending}) [$i/60]"
    sleep 10
  done

  log "  Run A: $CONCLUSION_A"
  log "  Run B: $CONCLUSION_B"
  log ""

  log "[6] Analyzing results for $ROUND_VERSION..."

  MANIFEST=$(curl -sf "https://registry.npmjs.org/$PKG/$ROUND_VERSION" 2>/dev/null || echo "{}")
  M_SHASUM=$(echo "$MANIFEST" | jq -r '.dist.shasum // empty')
  M_INTEGRITY=$(echo "$MANIFEST" | jq -r '.dist.integrity // empty')
  TARBALL_URL=$(echo "$MANIFEST" | jq -r '.dist.tarball // empty')

  if [ -z "$M_SHASUM" ]; then
    log "  No manifest found — neither publish succeeded at the registry level."
    log ""
    continue
  fi

  log "  manifest shasum:    $M_SHASUM"
  log "  manifest integrity: $M_INTEGRITY"
  log ""

  CDN_TARBALL=$(mktemp)
  curl -sL -o "$CDN_TARBALL" "$TARBALL_URL"
  T_SHA1=$(shasum -a 1 "$CDN_TARBALL" | cut -d' ' -f1)
  T_SHA512_HEX=$(shasum -a 512 "$CDN_TARBALL" | cut -d' ' -f1)
  T_INTEGRITY="sha512-$(echo "$T_SHA512_HEX" | xxd -r -p | base64 | tr -d '\n')"

  SHA1_OK="MATCH"
  SHA512_OK="MATCH"
  [ "$M_SHASUM" != "$T_SHA1" ] && SHA1_OK="MISMATCH"
  [ "$M_INTEGRITY" != "$T_INTEGRITY" ] && SHA512_OK="MISMATCH"

  log "  SHA-1:   $SHA1_OK"
  log "  SHA-512: $SHA512_OK"

  EXTRACT_DIR=$(mktemp -d)
  tar xzf "$CDN_TARBALL" -C "$EXTRACT_DIR" 2>/dev/null || true
  CDN_CONTENT=$(cat "$EXTRACT_DIR/package/index.js" 2>/dev/null || echo "N/A")
  CDN_DESC=$(jq -r '.description // empty' "$EXTRACT_DIR/package/package.json" 2>/dev/null || echo "N/A")
  log "  CDN content: $CDN_CONTENT"
  log "  CDN description: $CDN_DESC"
  log ""

  log "[7] Attestation analysis..."
  sleep 5

  ATTEST_JSON=$(curl -sf "https://registry.npmjs.org/-/npm/v1/attestations/$PKG@$ROUND_VERSION" 2>/dev/null || echo '{"attestations":[]}')

  ATTEST_ANALYSIS=$(echo "$ATTEST_JSON" | python3 -c "
import json, sys, base64

data = json.load(sys.stdin)
attestations = data.get('attestations', [])
print(f'Total attestations: {len(attestations)}')

hashes = set()
refs = set()
shas = set()

for i, a in enumerate(attestations):
  pred_type = a.get('predicateType', 'N/A').split('/')[-1]
  payload = a.get('bundle', {}).get('dsseEnvelope', {}).get('payload', '')
  if not payload:
    continue
  pred = json.loads(base64.b64decode(payload))

  # Subject hashes (tarball digests)
  for s in pred.get('subject', []):
    for algo, digest in s.get('digest', {}).items():
      hashes.add(digest)
      print(f'  [{i+1}] {pred_type}: {algo}={digest[:40]}...')

  # Extract git ref and SHA from SLSA provenance
  bd = pred.get('predicate', {}).get('buildDefinition', {})

  # Try resolvedDependencies (SLSA v1.0)
  for dep in bd.get('resolvedDependencies', []):
    uri = dep.get('uri', '')
    digest = dep.get('digest', {})
    if 'github.com' in uri:
      refs.add(uri)
      print(f'  [{i+1}] source: {uri}')
    if 'gitCommit' in digest:
      shas.add(digest['gitCommit'])
      print(f'  [{i+1}] commit: {digest[\"gitCommit\"]}')

  # Try externalParameters (SLSA v1.0)
  ep = bd.get('externalParameters', {})
  workflow = ep.get('workflow', {})
  if workflow.get('ref'):
    refs.add(workflow['ref'])
    print(f'  [{i+1}] workflow ref: {workflow[\"ref\"]}')
  source = ep.get('source', {})
  if source.get('ref'):
    refs.add(source['ref'])
    print(f'  [{i+1}] source ref: {source[\"ref\"]}')

  # Try invocation.configSource (SLSA v0.2)
  inv = pred.get('predicate', {}).get('invocation', {})
  cs = inv.get('configSource', {})
  if cs.get('entryPoint'):
    print(f'  [{i+1}] entry: {cs[\"entryPoint\"]}')
  if cs.get('digest', {}).get('sha1'):
    shas.add(cs['digest']['sha1'])

print(f'')
print(f'Unique subject hashes: {len(hashes)}')
print(f'Unique git refs:       {len(refs)}')
print(f'Unique git commits:    {len(shas)}')

if len(hashes) > 1:
  print('*** MULTIPLE TARBALL HASHES — DUAL-PUBLISH DETECTED ***')
if len(refs) > 1:
  print('*** MULTIPLE GIT REFS — CROSS-REF RACE CONFIRMED ***')
  for r in sorted(refs):
    print(f'    {r}')
if len(shas) > 1:
  print('*** MULTIPLE GIT COMMITS — DIFFERENT SOURCE CODE ***')
  for s in sorted(shas):
    print(f'    {s}')
" 2>/dev/null || echo "(parse error)")

  log "$ATTEST_ANALYSIS"
  log ""

  if [ "$SHA1_OK" = "MISMATCH" ] || [ "$SHA512_OK" = "MISMATCH" ]; then
    log "  RESULT: INTEGRITY MISMATCH + DUAL-REF PROVENANCE"
    log "  This is the next@15.1.1-canary.0 scenario — two legitimate CI runs"
    log "  from different git refs both published with provenance, creating"
    log "  multiple valid attestations referencing different source commits"
    log "  while the registry ended up in an inconsistent state."
  elif [ "$CONCLUSION_A" = "success" ] && [ "$CONCLUSION_B" = "success" ]; then
    log "  RESULT: BOTH SUCCEEDED, INTEGRITY CONSISTENT"
    log "  Both CI runs completed successfully. Registry may have processed"
    log "  them sequentially (no race triggered this round)."
  elif [ "$CONCLUSION_A" = "success" ] || [ "$CONCLUSION_B" = "success" ]; then
    log "  RESULT: ONE SUCCEEDED"
    log "  Only one publish landed. Check attestations for orphaned entries."
  else
    log "  RESULT: BOTH FAILED"
  fi

  rm -f "$CDN_TARBALL"
  rm -rf "$EXTRACT_DIR"
  log ""

  if [ "$ROUND" -lt "$ROUNDS" ]; then
    log "  Waiting before next round..."
    sleep 5
  fi
done

log ""
log "=========================================="
log "Test complete. Results: $RESULT_FILE"
log "=========================================="
