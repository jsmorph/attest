# NitroTPM Attestation - Working Solution

## Summary

Successfully built an attestable AMI using Nix that retrieves real NitroTPM attestation documents signed by the AWS Nitro Hypervisor.

## Working AMI

Latest working AMI: `ami-09187dc8cbd9de28f` (us-east-2)

## Solution

The key was building `nitro-tpm-attest` from the NitroTPM-Tools source using crane (Nix Rust builder). The tool successfully retrieves attestation documents without needing certificate configuration.

### app.sh
```bash
#!/bin/bash
set -euo pipefail

echo "=== ATTESTATION START ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Get attestation document and base64 encode it
nitro-tpm-attest | base64

echo "=== ATTESTATION END ==="
```

### flake.nix

Key additions:
1. Added `crane` and `rust-overlay` inputs for building Rust packages
2. Built `nitro-tpm-attest` from NitroTPM-Tools source
3. Included it in systemPackages and service path

## Attestation Document Contents

The attestation document is CBOR encoded, COSE signed, and contains:
- `module_id`: TPM identifier (e.g., `i-02eb2b494e03e23b3-tpm0000000000000000`)
- `digest`: Hash algorithm used (SHA384)
- `timestamp`: When the document was generated
- `nitrotpm_pcrs`: All 24 PCR values (SHA384)
- `certificate`: TPM certificate chain
- `cabundle`: AWS Nitro Enclaves CA certificate chain
- `public_key`, `user_data`, `nonce`: Optional fields

## Build & Run

```bash
# Build on dev
scp app.sh flake.nix dev:~/attest/
ssh dev "cd ~/attest && nix build .#raw-image --system x86_64-linux"
ssh dev "cd ~/attest && AWS_DEFAULT_REGION=us-east-2 nix run .#create-ami -- result/nixos-tee_1.raw"

# Run
AWS_DEFAULT_REGION=us-east-2 ./run.sh <ami-id>
```

## Technical Details

- `nitro-tpm-attest` uses TPM vendor commands to request attestation from NitroTPM
- The attestation document is signed by the Nitro Hypervisor
- Certificate chain roots to `aws.nitro-enclaves` CA
- PCR4, PCR7, PCR12 contain attestable AMI measurements

## Previous Issue (Resolved)

The original "No such file or directory (os error 2)" error with hash file `b504a22e79caeae493497c7e9c1073fb28823428c845e95874439dec0f792dc4` was related to EK certificate verification. This was a red herring - the issue was that the binary wasn't built correctly. Building with crane from source resolved it.

## Files

- `flake.nix` - Nix flake with crane-based nitro-tpm-attest build
- `app.sh` - Simple script calling nitro-tpm-attest
- `run.sh` - Launches AMI and captures console output
