#!/bin/bash
set -euo pipefail

echo "=== ATTESTATION START ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

USER_DATA="example-request-id-$(date +%s)"
USER_DATA_HASH=$(echo -n "$USER_DATA" | sha256sum | cut -d' ' -f1)

echo "UserData: $USER_DATA"
echo "UserDataHash: $USER_DATA_HASH"

# Use tpm2_quote to create attestation with PCR values
if command -v tpm2_createek &>/dev/null; then
    echo "Creating TPM attestation quote..."
    cd /tmp
    # Create endorsement key
    tpm2_createek -c ek.ctx -G rsa2048 2>&1 || echo "EK creation failed"
    # Create attestation key
    tpm2_createak -C ek.ctx -c ak.ctx -G rsa2048 -g sha256 -s rsassa 2>&1 || echo "AK creation failed"
    # Get quote with PCRs 4,7,12
    if tpm2_quote -c ak.ctx -l sha256:4,7,12 -q "$USER_DATA_HASH" -m quote.msg -s quote.sig 2>&1; then
        echo "Quote: $(base64 -w0 quote.msg)"
        echo "Signature: $(base64 -w0 quote.sig)"
    else
        echo "ERROR: tpm2_quote failed"
    fi
    rm -f ek.ctx ak.ctx quote.msg quote.sig 2>/dev/null
else
    echo "WARNING: tpm2 tools not available"
fi

if command -v tpm2_pcrread &>/dev/null; then
    echo "=== PCR VALUES ==="
    tpm2_pcrread sha384:4,7,12
    echo "=== END PCR VALUES ==="
fi

echo "=== ATTESTATION END ==="
