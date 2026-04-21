#!/bin/bash
set -euo pipefail

echo "=== Attestation check ==="
echo ""

echo "--- next@15.1.1-canary.0 ---"
curl -s "https://registry.npmjs.org/-/npm/v1/attestations/next@15.1.1-canary.0" | python3 -c "
import json, sys, base64
data = json.load(sys.stdin)
attestations = data.get('attestations', [])
print(f'Total attestations: {len(attestations)}')

hashes = set()
for i, a in enumerate(attestations):
    pred_type = a.get('predicateType', 'N/A').split('/')[-1]
    payload = a.get('bundle', {}).get('dsseEnvelope', {}).get('payload', '')
    if payload:
        pred = json.loads(base64.b64decode(payload))
        for s in pred.get('subject', []):
            for algo, digest in s.get('digest', {}).items():
                hashes.add(digest)
                ref = pred.get('predicate', {}).get('buildDefinition', {}).get('externalParameters', {}).get('workflow', {}).get('ref', 'N/A')
                print(f'  Attestation {i+1} [{pred_type}]: {algo}={digest[:40]}... ref={ref}')

print(f'\nUnique hashes: {len(hashes)}')
if len(hashes) > 1:
    print('MULTIPLE DIFFERENT HASHES')
elif len(hashes) == 1:
    print('Single hash — consistent')
else:
    print('No attestations found')
"

echo ""
echo "--- next@15.1.0 ---"
curl -s "https://registry.npmjs.org/-/npm/v1/attestations/next@15.1.0" | python3 -c "
import json, sys, base64
data = json.load(sys.stdin)
attestations = data.get('attestations', [])
hashes = set()
for a in attestations:
    payload = a.get('bundle', {}).get('dsseEnvelope', {}).get('payload', '')
    if payload:
        pred = json.loads(base64.b64decode(payload))
        for s in pred.get('subject', []):
            for _, digest in s.get('digest', {}).items():
                hashes.add(digest)
print(f'Attestations: {len(attestations)}, Unique hashes: {len(hashes)}')
if len(hashes) <= 1:
    print('Single hash — consistent')
else:
    print('Multiple hashes')
"

echo ""
echo "=== Done ==="
