#!/usr/bin/env bash

# Build a reproducible attestable AMI using Nix.
# Usage: ./nixbuild.sh [app.sh] [--debug]
#
# This script:
# 1. Optionally copies custom app.sh to nixapp.sh
# 2. Builds the NixOS image with nix build
# 3. Uploads to AWS via coldsnap
# 4. Registers the AMI with TPM support
# 5. Outputs AMI ID and PCR measurements

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX="${NIX:-/nix/var/nix/profiles/default/bin/nix}"

# Parse arguments
APP_SH=""
DEBUG=""
for arg in "$@"; do
  case "$arg" in
    --debug) DEBUG="-debug" ;;
    *) APP_SH="$arg" ;;
  esac
done

# If custom app.sh provided, copy to nixapp.sh
if [[ -n "$APP_SH" ]]; then
  if [[ ! -f "$APP_SH" ]]; then
    echo "error: $APP_SH not found" >&2
    echo "Usage: $0 [app.sh] [--debug]" >&2
    exit 1
  fi
  echo "Embedding custom application: $APP_SH"
  cp "$APP_SH" "$SCRIPT_DIR/nixapp.sh"
  chmod +x "$SCRIPT_DIR/nixapp.sh"
else
  echo "Using default nixapp.sh"
fi

# Ensure we're in the flake directory
cd "$SCRIPT_DIR"

# Build the image
PACKAGE="raw-image${DEBUG}"
echo "Building NixOS image (package: $PACKAGE)..."
echo "This may take a while on first run (downloading from cache.nixos.org)"

"$NIX" build ".#$PACKAGE" --system x86_64-linux --no-link --print-out-paths > /tmp/nix-build-result.txt
IMAGE_PATH="$(cat /tmp/nix-build-result.txt)"

echo "Image built: $IMAGE_PATH"

# Find the raw image file
RAW_IMAGE="$(find "$IMAGE_PATH" -name "*.raw" -type f | head -1)"
if [[ -z "$RAW_IMAGE" ]]; then
  echo "error: no .raw image found in $IMAGE_PATH" >&2
  ls -la "$IMAGE_PATH"
  exit 1
fi

echo "Raw image: $RAW_IMAGE"

# Extract PCR measurements if available
PCR_FILE="$(dirname "$RAW_IMAGE")/pcr_measurements.json"
if [[ -f "$PCR_FILE" ]]; then
  echo "=== PCR MEASUREMENTS ==="
  cat "$PCR_FILE"
  echo "=== END PCR MEASUREMENTS ==="
fi

# Upload to AWS and create AMI
echo "Uploading to AWS..."
AWS_REGION="${AWS_REGION:-us-east-2}"

AMI_NAME="${AMI_NAME:-nixos-tee_$(date -u +%Y%m%dT%H%M%SZ)}"

# Use the create-ami app from the flake
AMI_ID="$("$NIX" run ".#create-ami" -- "$RAW_IMAGE" 2>&1 | grep -oP 'ami-[a-z0-9]+' | tail -1)"

if [[ -z "$AMI_ID" ]]; then
  echo "error: failed to create AMI" >&2
  exit 1
fi

echo ""
echo "=== BUILD COMPLETE ==="
echo "AMI_ID=$AMI_ID"
if [[ -f "$PCR_FILE" ]]; then
  echo "PCR_JSON=$(cat "$PCR_FILE" | tr -d '\n')"
fi

# Note: nixapp.sh is tracked in git, no cleanup needed
