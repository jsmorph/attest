Build an attestable AMI using Nix.

The script [`build.sh`](build.sh) assumes an `ssh` host named `dev`
running a clean Amazon Linux 2023.  This host has all required
permissions.  This script does `ssh` and `scp` to build the attestable
AMI.  By default, `build.sh` uses `app.sh` as the application, which
is baked into the AMI with Nix.

The script `run.sh` runs the attestable AMI and gets the attestation
that `app.sh` prints.

