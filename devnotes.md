# Attestable AMI Development Notes

## Working AMI

- **AMI ID**: `ami-0570efbdbea053cb4` (us-east-2)
- **Created**: 2026-01-01

## Build Process

1. Build image on x86_64 instance with Nix:
   ```bash
   ssh dev 'cd ~/attest && nix build .#raw-image --system x86_64-linux'
   ```

2. Create AMI using coldsnap:
   ```bash
   ssh dev 'AWS_DEFAULT_REGION=us-east-2 nix run .#create-ami -- result/nixos-tee_1.raw'
   ```

## Run Process

```bash
AWS_DEFAULT_REGION=us-east-2 ./run.sh <ami-id>
```

This launches an instance, waits for the app to run, and retrieves console output.

## Key Technical Details

### Console Output
- EC2 `get-console-output` API returns kernel messages and early boot
- To get app output: use `journald.extraConfig` with `ForwardToConsole=yes` and `TTYPath=/dev/ttyS0`
- Systemd service uses `StandardOutput=journal+console` to route stdout to journal → console

### App Packaging
- App script must be a nix store package (`pkgs.writeShellScriptBin`), not an `/etc` file
- dm-verity protected image has read-only root; `/etc/app.sh` approach doesn't work

### PCR Values
Working output shows PCR 4, 7, 12 (sha384):
```
4 : 0x88692841095F5F748405D7BBAF0E7593A34BCCD89A3A92C3AC64A174EAF6C4845DD8B0FCA46E00CBC933BABFA065595F
7 : 0x98441C7F7625D10058C47683AEC486CE311C633235EB555593A7EE791121E3578AE72D04ECEF661F272D59058B77AF35
12: 0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
```

### Missing: nitro-tpm-attest
The `nitro-tpm-attest` binary isn't included. On Amazon Linux it's from `aws-nitro-tpm-tools`. For NixOS, build from https://github.com/aws/NitroTPM-Tools

## AWS Permissions

### Build (on dev instance via IAM role)
- ec2:CreateSnapshot, ec2:RegisterImage, ec2:DescribeSnapshots, ec2:DescribeImages
- ebs:StartSnapshot, ebs:PutSnapshotBlock, ebs:CompleteSnapshot

### Run (local AWS CLI)
- ec2:RunInstances, ec2:DescribeInstances, ec2:GetConsoleOutput, ec2:TerminateInstances

## References

- [NitroTPM Attestation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nitrotpm-attestation.html)
- [Get Attestation Document](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/attestation-get-doc.html)
- [NitroTPM-Tools](https://github.com/aws/NitroTPM-Tools)
- [nitrotpm-attestation-samples](https://github.com/aws/nitrotpm-attestation-samples)
- [journald.conf ForwardToConsole](https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html)
