#!/bin/bash
set -euo pipefail

echo "=== ATTESTATION START ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Get attestation document and base64 encode it
nitro-tpm-attest | base64

echo "=== ATTESTATION END ==="
