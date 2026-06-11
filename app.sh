#!/bin/sh
set -eu

# Example: Run a container image without Docker
# This demonstrates that app.sh can execute arbitrary workloads.
# Since app.sh is covered by PCR4 (via dm-verity), anything it does
# is transitively attested. The container output is hashed and bound
# to the attestation via user_data for verification.

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

curl -fsSL \
    https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz \
    -o alpine-minirootfs.tar.gz
tar -xzf alpine-minirootfs.tar.gz

chroot . /bin/sh -c 'echo "Hello from Alpine container"' > /tmp/container.txt 2>&1
cat /tmp/container.txt

cd /
rm -rf "$WORKDIR"

# Hash container output (SHA-384 hex string) for attestation binding
sha384sum /tmp/container.txt | cut -d' ' -f1 > /tmp/user_data.txt

# Output attestation with user_data
echo "=== ATTESTATION START ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
nitro-tpm-attest --user-data /tmp/user_data.txt | base64
echo "=== ATTESTATION END ==="
