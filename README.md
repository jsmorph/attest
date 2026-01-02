# Attestable AMI

Build and verify attestable AMIs using NixOS and AWS NitroTPM.

## Prerequisites

An SSH host named `dev` running Amazon Linux 2023 with Nix installed and appropriate AWS permissions to create AMIs and launch EC2 instances.

## Build

Build the AMI and get predicted PCR values:

```bash
./build.sh
```

This copies flake.nix and app.sh to the dev host, builds a NixOS image with dm-verity, and registers it as an AMI. The script outputs the AMI ID and predicted PCR values (PCR4 measures the UKI, PCR7 measures secure boot policy).

## Run

Launch an instance and capture the attestation:

```bash
./run.sh <ami-id> | tee attestation_output.txt
```

The instance runs app.sh on boot, which outputs a base64-encoded NitroTPM attestation document between `ATTESTATION START` and `ATTESTATION END` markers. The instance terminates automatically after output is captured.

## Extract

Extract the base64 attestation from the console output:

```bash
./extract.sh < attestation_output.txt > attest.b64
```

## Verify

Parse and verify the attestation signature and certificate chain:

```bash
uv run parse_attestation.py attest.b64
```

This validates the COSE signature, verifies the certificate chain to the AWS Nitro root CA, and displays PCR values. Compare PCR4 against the build-time prediction to confirm the image is unmodified.

## Files

- `flake.nix` - NixOS configuration for the attestable image
- `app.sh` - Application script baked into the image
- `build.sh` - Builds the image and creates an AMI
- `run.sh` - Launches an instance and captures console output
- `extract.sh` - Extracts base64 attestation from console output
- `parse_attestation.py` - Parses and verifies the attestation document
