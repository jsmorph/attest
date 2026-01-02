# Attestable AMI Developer Documentation

## Overview

This system builds reproducible, attestable Amazon Machine Images (AMIs) using NixOS and AWS NitroTPM. The resulting images provide cryptographic proof of their integrity at runtime, enabling remote verification that an EC2 instance is running exactly the software that was built.

The core value proposition is **reproducible attestation**: given the same Nix flake inputs, the build produces identical PCR (Platform Configuration Register) values. A remote verifier can compare runtime attestation PCRs against build-time predictions to confirm the instance has not been tampered with.

## Architecture

The system consists of three phases: build, runtime, and verification.

### Build Phase

```
flake.nix + app.sh
        │
        ▼
   nix build .#raw-image
        │
        ▼
  NixOS image with:
  ├── Unified Kernel Image (UKI)
  ├── dm-verity protected root filesystem
  ├── Embedded application (app.sh)
  └── Predicted PCR values (tpm_pcr.json)
        │
        ▼
   create-ami (registers as AMI)
```

The Nix flake leverages the `nitro-tee` library from AWS to produce a NixOS image optimized for trusted execution. The image uses a Unified Kernel Image format where the kernel, initrd, and command line are bundled into a single signed EFI binary. The root filesystem is protected by dm-verity, which provides read-only integrity verification using a Merkle tree.

### Runtime Phase

```
EC2 Instance Boot
        │
        ▼
  UEFI Secure Boot
  (measures UKI into PCR4)
        │
        ▼
  Linux kernel starts
  (dm-verity validates root FS)
        │
        ▼
  systemd launches app.service
        │
        ▼
  app.sh downloads Alpine minirootfs
  and runs workload via chroot
        │
        ▼
  Container output hashed (SHA-384)
  and passed to nitro-tpm-attest
        │
        ▼
  NitroTPM returns signed attestation
  containing PCR values and user_data
        │
        ▼
  Attestation output to serial console
```

The NitroTPM is a virtual TPM 2.0 device provided by the AWS Nitro hypervisor. It maintains PCR values that reflect measurements taken during the boot process. The `nitro-tpm-attest` tool requests an attestation document from the NitroTPM, which returns a COSE-signed structure containing the current PCR values and a certificate chain rooted at AWS.

### Verification Phase

```
Console output (captured via EC2 API)
        │
        ▼
  extract.sh (isolates base64 attestation)
        │
        ▼
  parse_attestation.py
  ├── Decode COSE Sign1 structure
  ├── Verify certificate chain to AWS root
  ├── Validate COSE signature
  ├── Extract and display PCR values
  └── Display user_data (container output hash)
        │
        ▼
  Compare PCR4 against build prediction
  Compare user_data against sha384sum of expected output
```

## Security Model

### Trust Chain

The security model establishes trust through the following chain:

1. **AWS Nitro Hypervisor**: The root of trust. AWS signs attestation certificates with a key chaining to the AWS Nitro Enclaves root CA.

2. **UEFI Secure Boot**: The hypervisor measures the UKI into PCR4 before execution. This measurement covers the kernel, initrd, and kernel command line.

3. **dm-verity**: The root filesystem is mounted read-only with dm-verity verification. The dm-verity root hash is embedded in the kernel command line (and thus covered by PCR4).

4. **Application Integrity**: Since the application (app.sh) is embedded in the Nix store within the dm-verity protected filesystem, any modification would invalidate the dm-verity verification.

### PCR Registers

The NitroTPM maintains 24 PCR registers using SHA-384. The relevant registers for this system are:

| PCR | Purpose | Measured By |
|-----|---------|-------------|
| 0 | UEFI firmware | Nitro hypervisor |
| 4 | UKI (kernel + initrd + cmdline) | UEFI boot loader |
| 7 | Secure Boot policy | UEFI |
| 9 | Initrd contents | Linux EFI stub |
| 11 | Unified kernel image components | systemd-stub |

**PCR4 is the critical register for attestation.** It contains a hash of the entire Unified Kernel Image, which transitively covers:
- The Linux kernel
- The initrd (including the dm-verity root hash)
- The kernel command line (including dm-verity parameters)

Since the dm-verity root hash is in the kernel command line, PCR4 effectively covers the entire root filesystem contents, including the application.

### Attestation Document Structure

The attestation document is a CBOR-encoded, COSE Sign1-signed structure:

```
COSE_Sign1 = [
    protected_header,    # Contains algorithm identifier (ES384)
    unprotected_header,  # Empty
    payload,             # CBOR map with attestation data
    signature            # ECDSA-P384 signature
]
```

The payload contains:
- `module_id`: Instance and TPM identifier
- `digest`: Hash algorithm used (SHA384)
- `timestamp`: Attestation generation time (milliseconds since epoch)
- `nitrotpm_pcrs`: Map of PCR index to 48-byte SHA-384 values
- `user_data`: Optional application-provided data bound to the attestation
- `certificate`: DER-encoded X.509 certificate for signature verification
- `cabundle`: Array of DER-encoded CA certificates forming chain to AWS root

The `user_data` field allows applications to bind arbitrary data to the attestation. In this system, it contains the SHA-384 hash of the container output, enabling verifiers to confirm both the image integrity (via PCRs) and the specific workload output (via user_data).

### Certificate Chain

The attestation includes a certificate chain:

1. **AWS Nitro Enclaves Root CA** (self-signed, 2019-2049)
2. **Regional intermediate CA** (signed by root)
3. **Zonal CA** (signed by regional)
4. **Instance CA** (signed by zonal)
5. **Attestation certificate** (signed by instance CA, contains public key for COSE signature)

The verifier must confirm the chain terminates at the known AWS Nitro root CA and that each certificate signature is valid.

## Build Process

### Prerequisites

- SSH access to a build host (`dev`) running Amazon Linux 2023
- Nix installed on the build host
- AWS credentials with permissions to create AMIs

### Nix Flake Structure

The `flake.nix` defines:

**Inputs:**
- `nixpkgs`: NixOS packages (unstable channel)
- `nitro-tee`: AWS library for building attestable images
- `crane`: Rust build system for compiling `nitro-tpm-attest`
- `rust-overlay`: Rust toolchain management

**Outputs:**
- `packages.raw-image`: Production image (no console access)
- `packages.raw-image-debug`: Debug image (console access enabled)
- `apps.create-ami`: Utility to register raw image as AMI

### Image Configuration

The `userConfig` NixOS module configures:

1. **Application service**: Systemd oneshot service running `app.sh` at boot
2. **Journal forwarding**: Console output forwarded to serial port for EC2 console access
3. **Headless configuration**: All getty services disabled to prevent console noise
4. **TPM environment**: `TPM2TOOLS_TCTI` set to access the NitroTPM device

### Build Commands

```bash
# On build host
nix build .#raw-image --system x86_64-linux

# Creates:
# result/nixos-tee_1.raw   - Raw disk image
# result/tpm_pcr.json      - Predicted PCR values
```

### AMI Registration

The `create-ami` app uploads the raw image to S3, creates an EBS snapshot, and registers an AMI. The resulting AMI ID is used to launch instances.

## Runtime Flow

### Boot Sequence

1. **UEFI initialization**: Nitro hypervisor initializes virtual UEFI firmware
2. **Secure Boot**: UEFI loads and measures UKI into PCR4
3. **Linux EFI stub**: Extracts and measures initrd into PCR9
4. **Kernel boot**: Mounts dm-verity protected root filesystem
5. **systemd init**: Starts configured services
6. **app.service**: Executes application after network is online

### Attestation Generation

The `app.sh` script:

1. Downloads Alpine Linux minirootfs tarball
2. Extracts it to a temporary directory
3. Runs a command inside the container via `chroot`
4. Captures container output to `/tmp/container.txt` (also displayed via `tee`)
5. Computes SHA-384 hash of the container output
6. Outputs `=== ATTESTATION START ===` marker
7. Outputs timestamp in ISO 8601 format
8. Calls `nitro-tpm-attest --user-data /tmp/user_data.txt` which:
   - Opens `/dev/tpmrm0` (TPM resource manager)
   - Includes the hash in the attestation's `user_data` field
   - Requests attestation from NitroTPM
   - Returns CBOR-encoded attestation document
9. Base64-encodes the attestation
10. Outputs `=== ATTESTATION END ===` marker

### Console Output

The systemd journal forwards to `/dev/ttyS0` (serial console). EC2's `get-console-output` API retrieves this output. The output includes kernel messages, systemd logs, and application output, all prefixed with timestamps and unit names.

## Verification

### Extracting Attestation

The `extract.sh` script processes console output:

1. Isolates lines between attestation markers
2. Filters to lines from the `app` systemd unit
3. Removes journal prefixes (`app[PID]: `)
4. Strips carriage returns and concatenates base64 fragments
5. Outputs clean base64 string

### Parsing and Verification

The `parse_attestation.py` script:

1. **Decodes COSE structure**: Parses CBOR, handles optional COSE tag
2. **Verifies certificate chain**: Confirms each certificate is signed by its issuer, terminating at AWS Nitro root
3. **Validates COSE signature**: Constructs Sig_structure, converts raw R||S signature to DER, verifies with ES384
4. **Extracts PCR values**: Displays all 24 PCR registers in hexadecimal
5. **Displays user_data**: Shows the application-provided data (container output hash)

### PCR Comparison

To verify image integrity:

1. Note PCR4 value from `tpm_pcr.json` during build
2. Run instance and extract attestation
3. Parse attestation and compare PCR4

If values match, the instance is running the exact image that was built. Any modification to the kernel, initrd, command line, or root filesystem contents would produce a different PCR4 value.

### User Data Verification

To verify the container output:

1. Observe the container output from console logs (e.g., "Hello from Alpine container")
2. Compute the expected hash: `echo "Hello from Alpine container" | sha384sum`
3. Compare against the `user_data` field in the attestation

If values match, the attestation cryptographically binds the specific container output to the signed attestation document. This proves the workload produced the expected output on the attested image.

## Files Reference

### `flake.nix`

Nix flake defining the attestable image build. Key components:
- `nitroTpmAttest`: Rust binary built from AWS NitroTPM-Tools
- `appScript`: Application embedded in the image
- `userConfig`: NixOS configuration module
- `raw-image`: Build output using nitro-tee library

### `flake.lock`

Pinned versions of all flake inputs ensuring reproducible builds.

### `app.sh`

Application script baked into the image. Runs at boot to:
1. Download and extract Alpine Linux minirootfs
2. Execute a workload inside the container via chroot
3. Hash the container output with SHA-384
4. Generate attestation with the hash bound as user_data

Modify this script to run different container workloads. The hash binding ensures attestation covers both the image (via PCR4) and the specific workload output (via user_data).

### `build.sh`

Build orchestration script. Copies flake files to build host, runs Nix build, creates AMI, and outputs predicted PCR values.

Environment variables:
- `BUILD_HOST`: SSH host for building (default: `dev`)
- `AWS_DEFAULT_REGION`: AWS region for AMI creation (default: `us-east-2`)

### `run.sh`

Instance launch and output capture script. Launches instance, polls console output until attestation appears or timeout, terminates instance on exit.

Environment variables:
- `AWS_DEFAULT_REGION`: AWS region (default: `us-east-2`)
- `INSTANCE_TYPE`: EC2 instance type (default: `c5.xlarge`)

### `extract.sh`

Console output parser. Reads from stdin, extracts base64 attestation, writes to stdout. Handles journal formatting and console noise.

### `parse_attestation.py`

Attestation verification tool. Uses `uv` for dependency management (`cbor2`, `cryptography`). Verifies signature and certificate chain, displays PCR values and user_data, exits with status 0 on valid signature.

### `clean.sh`

AWS resource cleanup script. Deregisters AMIs, deletes snapshots, and terminates stopped instances created on a specific date.

## References

### AWS Documentation

- [AWS Nitro TPM](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nitrotpm.html) - Overview of NitroTPM capabilities
- [NitroTPM Attestation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nitrotpm-attestation.html) - Attestation document format and verification
- [AWS NitroTPM-Tools](https://github.com/aws/NitroTPM-Tools) - Source for `nitro-tpm-attest` utility
- [AWS nitrotpm-attestation-samples](https://github.com/aws/nitrotpm-attestation-samples) - Nix library for building attestable images

### NixOS Documentation

- [NixOS Manual](https://nixos.org/manual/nixos/stable/) - NixOS configuration reference
- [Nix Flakes](https://nixos.wiki/wiki/Flakes) - Flake format and usage
- [nixpkgs profiles/headless.nix](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/profiles/headless.nix) - Headless system configuration

### TPM and Measured Boot

- [TCG PC Client Platform TPM Profile Specification](https://trustedcomputinggroup.org/resource/pc-client-platform-tpm-profile-ptp-specification/) - TPM 2.0 specification
- [TCG PC Client Platform Firmware Profile](https://trustedcomputinggroup.org/resource/pc-client-specific-platform-firmware-profile-specification/) - PCR usage conventions
- [Linux TPM Documentation](https://www.kernel.org/doc/html/latest/security/tpm/index.html) - Kernel TPM subsystem

### dm-verity

- [dm-verity Documentation](https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/verity.html) - Kernel dm-verity implementation
- [Android Verified Boot](https://source.android.com/docs/security/features/verifiedboot) - dm-verity usage in practice

### COSE and CBOR

- [RFC 9052 - COSE Structures and Process](https://datatracker.ietf.org/doc/html/rfc9052) - COSE Sign1 format
- [RFC 8949 - CBOR](https://datatracker.ietf.org/doc/html/rfc8949) - CBOR encoding specification
- [COSE Algorithms Registry](https://www.iana.org/assignments/cose/cose.xhtml) - Algorithm identifiers (ES384 = -35)

### Cryptography

- [FIPS 186-4](https://csrc.nist.gov/publications/detail/fips/186/4/final) - ECDSA specification
- [SEC 2: Recommended Elliptic Curve Domain Parameters](https://www.secg.org/sec2-v2.pdf) - P-384 curve parameters
