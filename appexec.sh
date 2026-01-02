#!/bin/bash
set -euo pipefail

# Fetch user-data from IMDS
USER_DATA=$(curl -s http://169.254.169.254/latest/user-data || true)

# If user-data starts with #!, save and execute it
if [[ "$USER_DATA" == "#!"* ]]; then
    echo "$USER_DATA" > /tmp/user-data.sh
    chmod +x /tmp/user-data.sh
    /tmp/user-data.sh
    sleep 60
fi

# Generate attestation
echo "=== ATTESTATION START ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
nitro-tpm-attest | base64
echo "=== ATTESTATION END ==="
