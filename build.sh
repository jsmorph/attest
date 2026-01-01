#!/bin/bash
set -euo pipefail

HOST="${BUILD_HOST:-dev}"
APP="${1:-app.sh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/$APP" ]]; then
    echo "error: $APP not found" >&2
    exit 1
fi

ssh "$HOST" 'command -v nix >/dev/null 2>&1' || {
    echo "Installing Nix on $HOST..."
    ssh "$HOST" 'curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes'
    ssh "$HOST" '. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh && nix --version'
}

echo "Copying files to $HOST..."
scp "$SCRIPT_DIR/flake.nix" "$SCRIPT_DIR/flake.lock" "$SCRIPT_DIR/$APP" "$HOST":~/attest/

echo "Building image on $HOST..."
ssh "$HOST" 'cd ~/attest && . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh && nix build .#raw-image --system x86_64-linux'

echo "Creating AMI..."
AMI_ID=$(ssh "$HOST" "cd ~/attest && . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh && AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-2} nix run .#create-ami -- result/nixos-tee_1.raw 2>&1 | grep 'AMI ID' | awk '{print \$NF}'")

echo "AMI ID: $AMI_ID"

echo "Predicted PCR values:"
ssh "$HOST" 'cat ~/attest/result/tpm_pcr.json'
