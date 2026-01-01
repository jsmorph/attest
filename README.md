Build an attestable AMI using Nix.

The script [`build.sh`](build.sh) assumes an `ssh` host named `dev`
running a clean Amazon Linux 2023.  This host has all required
permissions.  This script does `ssh` and `scp` to build the attestable
AMI.  By default, `build.sh` uses `app.sh` as the application, which
is baked into the AMI with Nix.

The script `run.sh` runs the attestable AMI and gets the attestation
that `app.sh` prints.

## Parsing Attestations

To parse PCR values from an attestation:

```bash
# Extract base64 attestation from run.sh output
AWS_DEFAULT_REGION=us-east-2 ./run.sh <ami-id> | \
  sed -n '/=== ATTESTATION START ===/,/=== ATTESTATION END ===/p' | \
  grep 'app\[' | sed 's/.*app\[[0-9]*\]: //' | \
  grep -v '===' | grep -v 'Timestamp:' | tr -d '\n' > attest.b64

# Parse PCRs (requires uv)
uv run parse_attestation.py attest.b64
```

