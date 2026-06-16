# Attestable AMI

Build and verify attestable AMIs using NixOS and AWS NitroTPM.

This system builds a "builder" image reproducibly, so that its measurements are predictable.  The builder image then builds an application image, which need not be reproducible.  To verify an application image, a verifier checks the attestation from the builder and confirms that the builder's own measurements match the known-good values derived from the reproducible build.  The application image is trustworthy because the builder that produced it is trustworthy.

## Prerequisites

An SSH host named `dev` must satisfy the build-host and runner-host requirements in [Dev Host Requirements](dev-host.md).  The short version is an x86_64 Amazon Linux 2023 host with `~/attest`, Nix daemon support, AWS CLI, outbound network access, and AWS permissions for EBS direct snapshot upload, AMI registration, EC2 launch, console output, termination, and optional role passing.  The detailed document also covers default region behavior, EC2 default VPC assumptions, disk requirements, cleanup permissions, and verification commands.

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

The instance runs app.sh on boot, which downloads an Alpine Linux minirootfs, runs a command via chroot, hashes the output with SHA-384, and includes this hash in the attestation's `user_data` field. The base64-encoded attestation appears between `ATTESTATION START` and `ATTESTATION END` markers. The instance terminates automatically after output is captured.

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

This validates the COSE signature, verifies the certificate chain to the AWS Nitro root CA, and displays PCR values and user data. Compare PCR4 against the build-time prediction to confirm the image is unmodified. The `User Data` field contains the SHA-384 hash of the container output, which can be verified with `echo "Hello from Alpine container" | sha384sum`.

## Running Custom Scripts

Build an AMI with `appexec.sh` to run custom scripts at boot:

```bash
./build.sh appexec.sh
```

Then use `exec.sh` to run the AMI with a script:

```bash
./exec.sh <ami-id> myscript.sh
```

The script must start with `#!` (e.g., `#!/bin/sh`). It runs before attestation, and clean app output is printed to stdout. Raw console output is saved to `execout.txt`.

Test the capability end-to-end:

```bash
./testexec.sh
```

## Files

- `flake.nix` - NixOS configuration for the attestable image
- `app.sh` - Application script that runs Alpine container demo
- `appexec.sh` - Application script that executes user-data scripts
- `build.sh` - Builds the image and creates an AMI
- `run.sh` - Launches an instance and captures console output
- `exec.sh` - Launches an instance with a custom script via user-data
- `extract.sh` - Extracts base64 attestation from console output
- `parse_attestation.py` - Parses and verifies the attestation document
- `testexec.sh` - End-to-end test for exec.sh
