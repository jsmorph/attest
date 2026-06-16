# Dev Host Requirements

## Scope

The `attest` repository uses a host named `dev` as the default remote build host for attestable AMIs.  The same host can also run `run.sh`, `exec.sh`, and `clean.sh` when those scripts are invoked there.  This document describes the generic `attest` requirements only, without requirements from any application that supplies its own user-data script.

`build.sh` copies `flake.nix`, `flake.lock`, and the selected application script to `~/attest` on the build host, runs `nix build .#raw-image --system x86_64-linux`, and registers the raw image as an AMI.  `run.sh` and `exec.sh` launch the resulting AMI through EC2, poll EC2 console output, and terminate the launched instance on exit.  `parse_attestation.py` verifies a downloaded attestation on the machine where `uv run parse_attestation.py` is executed.

## Host Roles

The build host and runner host can be the same EC2 instance.  The current scripts default to a build host named `dev`, but `BUILD_HOST` can point `build.sh` at another SSH target.  The runner host is whichever machine invokes `run.sh`, `exec.sh`, or `clean.sh`.

| Role | Required by | Responsibility |
| --- | --- | --- |
| Build host | `build.sh` | Build the NixOS raw image and register the AMI. |
| Runner host | `run.sh`, `exec.sh`, `clean.sh` | Launch AMIs, read console output, terminate instances, and clean AWS resources. |
| Launched instance profile | Optional `IAM_INSTANCE_PROFILE` in `exec.sh` | Give the launched AMI AWS permissions needed by the user-data script. |

## Host Baseline

The expected `dev` host is an x86_64 Linux host reachable through `ssh dev` and `scp dev:...`.  Amazon Linux 2023 is the known working operating system.  The default remote user in the current environment is `ec2-user`, with home directory `/home/ec2-user`.

| Requirement | Details |
| --- | --- |
| SSH | `ssh dev` and `scp` must work from the operator machine. |
| CPU architecture | `x86_64`, matching `nix build .#raw-image --system x86_64-linux`. |
| Operating system | Amazon Linux 2023 is the verified host OS. |
| Shell | Bash must be available for the repository scripts. |
| Home directory | The build script copies files into `~/attest`; create that directory before running `build.sh`. |
| Nix | Install Nix with daemon support and flakes.  The scripts source `/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`. |
| AWS CLI | Install `aws` on any host that runs `create-ami`, `run.sh`, `exec.sh`, or `clean.sh`. |
| curl | Required if `build.sh` has to install Nix. |
| Git and network fetches | Nix builds fetch pinned flake inputs from GitHub and Nix binary caches. |
| Disk | Leave enough root filesystem capacity for Nix downloads, the Nix store, raw image output, and logs. |
| Time | Keep host time synchronized so AWS signatures, TLS, and certificate checks work. |

If Nix is absent, `build.sh` attempts a daemon install through the official Nix installer.  That path needs permissions to install system services and write under `/nix`.  Preinstalling Nix avoids depending on an interactive privilege prompt during a build.

## Required Paths

`~/attest` is both the upload target for `build.sh` and the expected working directory for the remote build.  The directory must be writable by the SSH user.  A completed build leaves `result` pointing at the Nix output that contains `nixos-tee_1.raw` and `tpm_pcr.json`.

The Nix daemon profile script must exist at `/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`.  The scripts source that file before running `nix`.  If Nix lives somewhere else, edit the scripts or provide a compatibility file at that path.

The runner writes `execout.txt` in its current working directory.  A timeout or failed launched instance leaves that file as the primary console record.  Treat it as run output, because it can contain application logs and attestation material.

## AWS Region And EC2 Defaults

The scripts default to `AWS_DEFAULT_REGION=us-east-2`.  Override that variable when building or running in another region.  The build region determines where the AMI and EBS snapshot are created, and the run region determines where EC2 launches the AMI.

`run.sh` and `exec.sh` call `aws ec2 run-instances` without a subnet id, security group id, key pair, or launch template.  The selected region therefore needs a default VPC, a default subnet for the chosen Availability Zone, and a default security group.  The launched instance needs outbound network access for whatever the image or user-data script does at boot.

The default instance type is `c5.xlarge`.  Use an instance type that supports NitroTPM, UEFI boot, ENA, and the AMI architecture.  `exec.sh` accepts `INSTANCE_TYPE`, `IAM_INSTANCE_PROFILE`, `ROOT_VOLUME_SIZE_GB`, `POLL_ATTEMPTS`, and `EXEC_ENV_VARS` as environment variables.

## AWS Permissions

The build host role needs permissions for EBS direct snapshot upload and AMI registration.  The `create-ami` app comes from the AWS NitroTPM Nix sample and uses `coldsnap upload`, which writes the raw disk image through the EBS direct APIs before calling `aws ec2 register-image`.  The active helper registers an HVM, UEFI, ENA-enabled AMI with TPM support and root device `/dev/xvda`.

| Use | AWS actions |
| --- | --- |
| Upload raw image through EBS direct APIs | `ebs:StartSnapshot`, `ebs:PutSnapshotBlock`, `ebs:CompleteSnapshot` |
| Wait for snapshot completion | `ec2:DescribeSnapshots` |
| Register the AMI | `ec2:RegisterImage` |
| Inspect AMIs after creation | `ec2:DescribeImages` |

The runner host role needs EC2 launch and console permissions.  `run.sh` and `exec.sh` both launch one instance, wait for it to run, poll console output, and terminate it on exit.  `exec.sh` also passes a user-data file to the launched instance.

| Use | AWS actions |
| --- | --- |
| Launch instances | `ec2:RunInstances` |
| Wait for instance state | `ec2:DescribeInstances` |
| Read serial console output | `ec2:GetConsoleOutput` |
| Terminate launched instances | `ec2:TerminateInstances` |
| Pass an instance profile from `exec.sh` | `iam:PassRole` on the IAM role contained in the selected instance profile |

`clean.sh` needs destructive cleanup permissions.  Use that script only with an AWS role that is allowed to remove the images, snapshots, and stopped instances it selects.  The script currently filters by creation or launch time in the selected region.

| Use | AWS actions |
| --- | --- |
| Find owned AMIs | `ec2:DescribeImages` |
| Deregister AMIs | `ec2:DeregisterImage` |
| Find snapshots | `ec2:DescribeSnapshots` |
| Delete snapshots | `ec2:DeleteSnapshot` |
| Find stopped instances | `ec2:DescribeInstances` |
| Terminate stopped instances | `ec2:TerminateInstances` |

The generic `attest` scripts do not require an S3 bucket.  AMI creation uses EBS direct APIs rather than staging raw images in S3.  A user-data script can use S3 after launch, and those permissions belong on the launched instance profile rather than the build host unless the runner host also calls `aws s3`.

## Network Requirements

The build host needs outbound HTTPS access to GitHub, `cache.nixos.org`, Nix substituters configured for the host, AWS EC2 endpoints, and AWS EBS endpoints in the selected region.  If Nix is installed by `build.sh`, the host also needs outbound HTTPS access to `nixos.org`.  Corporate proxies or locked-down VPC egress must allow those destinations.

The launched instance needs outbound network access required by the embedded application or user-data script.  The default `app.sh` downloads an Alpine minirootfs over HTTPS.  `appexec.sh` reads user data from IMDS at `169.254.169.254` and then runs the provided script before requesting a NitroTPM attestation.

No inbound SSH access to the launched attestation instance is required by the scripts.  The runner reads boot output through the EC2 console API.  The default security group can therefore keep inbound rules closed if the application does not need inbound traffic.

## Verification Commands

Run these commands from the operator machine to check the `dev` host before a build.  They avoid changing remote state.  A failure identifies the missing host capability directly.

```bash
ssh dev 'printf "home=%s\n" "$HOME"; uname -a'
ssh dev 'command -v nix; command -v aws; command -v curl'
ssh dev 'test -d ~/attest && test -w ~/attest'
ssh dev '. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh && nix --version'
ssh dev 'AWS_DEFAULT_REGION=us-east-2 aws sts get-caller-identity --output json'
ssh dev 'df -h / /tmp 2>/dev/null || df -h /'
```

Run this command only when the role is expected to launch instances.  It checks account identity, not all IAM actions.  AWS IAM can still deny a later build or run if the role lacks one of the actions listed above.

```bash
ssh dev 'AWS_DEFAULT_REGION=us-east-2 aws ec2 describe-account-attributes --attribute-names supported-platforms --output json'
```

## References

Authoritative references for this host configuration:

| Topic | Reference |
| --- | --- |
| NitroTPM | <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nitrotpm.html> |
| NitroTPM attestation | <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/nitrotpm-attestation.html> |
| Attestable AMIs | <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/attestable-ami.html> |
| EBS direct APIs | <https://docs.aws.amazon.com/ebs/latest/userguide/ebs-accessing-snapshot.html> |
| EC2 `RunInstances` | <https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_RunInstances.html> |
| EC2 `GetConsoleOutput` | <https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_GetConsoleOutput.html> |
| Passing IAM roles | <https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_passrole.html> |
| AWS NitroTPM Nix sample | <https://github.com/aws/nitrotpm-attestation-samples/tree/main/nix> |
| `coldsnap` | <https://github.com/awslabs/coldsnap> |
