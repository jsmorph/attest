#!/bin/bash
# Extract base64 attestation from run.sh output
# Usage: ./run.sh <ami-id> | ./extract.sh > attest.b64

set -euo pipefail

# Read stdin, extract only base64 from app output lines between markers
# Filter out Timestamp line, strip carriage returns, handle garbage

awk '/ATTESTATION START/{found=1; next} /ATTESTATION END/{found=0} found' | \
tr -d '\r' | \
grep 'app\[' | \
grep -v 'Timestamp' | \
sed 's/.*app\[[0-9]*\]: //' | \
tr -d '\n' | \
grep -oE '[A-Za-z0-9+/=]+' | \
tr -d '\n'
