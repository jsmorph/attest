#!/bin/bash
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

AMI_ID="${1:-}"
SCRIPT_FILE="${2:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c5.xlarge}"

if [[ -z "$AMI_ID" || -z "$SCRIPT_FILE" ]]; then
    echo "Usage: $0 <ami-id> <script-file>" >&2
    exit 1
fi

if [[ ! -f "$SCRIPT_FILE" ]]; then
    echo "Error: $SCRIPT_FILE not found" >&2
    exit 1
fi

echo "Launching instance with AMI $AMI_ID and user-data from $SCRIPT_FILE..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --user-data "file://$SCRIPT_FILE" \
    --count 1 \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance: $INSTANCE_ID"

cleanup() {
    echo "Terminating instance $INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
}
trap cleanup EXIT

echo "Waiting for instance to run..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

echo "Polling console output..."
for i in {1..60}; do
    OUTPUT=$(aws ec2 get-console-output --instance-id "$INSTANCE_ID" --latest --query Output --output text 2>/dev/null || true)
    if echo "$OUTPUT" | grep -qE "ATTESTATION END|ERROR:|Failed"; then
        echo "$OUTPUT" > execout.txt
        grep 'app\[' execout.txt | sed 's/.*app\[[0-9]*\]: //'
        if echo "$OUTPUT" | grep -q "ATTESTATION END"; then
            exit 0
        else
            exit 1
        fi
    fi
    sleep 2
done

echo "Timeout waiting for output." >&2
OUTPUT=$(aws ec2 get-console-output --instance-id "$INSTANCE_ID" --latest --query Output --output text)
echo "$OUTPUT" > execout.txt
grep 'app\[' execout.txt | sed 's/.*app\[[0-9]*\]: //'
exit 1
