# Plan: Build Attestable AMI with Nix

Build an attestable AMI using Nix that runs `app.sh`, which gets a NitroTPM attestation and prints it as JSON. Development happens on a remote x86_64 EC2 instance (`dev`) accessed via ssh/scp.

## Tasks

- [x] Fix flake.nix to use app.sh directly
- [x] Test ssh connectivity to dev: `ssh dev ls /`
- [x] Check if Nix is installed on dev, install if needed
- [x] Build the NixOS image on dev
- [x] Create the AMI via create-ami
- [x] Write run.sh to launch AMI and get attestation
- [x] Document everything in devnotes.md
- [ ] Add nitro-tpm-attest to image (build from NitroTPM-Tools)
- [ ] Clean up old test AMIs/snapshots

## Technical Details

The `nitrotpm-attestation-samples` nix flake provides:
- `tee-image`: Creates dm-verity protected, UEFI bootable NixOS images
- `create-ami`: Uploads raw images to EC2 via EBS direct API
- PCR measurements stored in PCR4 (UKI measurement)

Requirements:
- x86_64 architecture (NitroTPM requirement)
- UEFI boot mode
- Instance types supporting NitroTPM (e.g., c5.xlarge, m5.xlarge)

## Files to Create

### build.sh
```
Usage: ./build.sh [app.sh]
```
1. Install Nix on dev (with flakes enabled) if not present
2. Copy flake.nix, flake.lock, and app script to dev
3. Build image: `nix build .#raw-image --system x86_64-linux`
4. Create AMI: `nix run .#create-ami -- <raw-image-path>`
5. Output AMI ID and PCR measurements

### run.sh
```
Usage: ./run.sh <ami-id>
```
1. Launch EC2 instance with NitroTPM enabled, UEFI boot
2. Wait for instance state: running → stopped
3. Get console output via `aws ec2 get-console-output`
4. Parse and display attestation
5. Terminate instance

### devnotes.md
Development notes with links to authoritative documentation.

## AWS Permissions Required

Build (on dev):
- ec2:CreateSnapshot, ec2:RegisterImage, ec2:DescribeSnapshots, ec2:DescribeImages
- ebs:PutSnapshotBlock

Run:
- ec2:RunInstances, ec2:DescribeInstances, ec2:GetConsoleOutput, ec2:TerminateInstances
