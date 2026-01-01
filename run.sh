#!/bin/bash
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

AMI_ID="${1:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c5.xlarge}"

if [[ -z "$AMI_ID" ]]; then
    echo "Usage: $0 <ami-id>" >&2
    exit 1
fi

echo "Launching instance with AMI $AMI_ID..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
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

echo "Polling console output for attestation..."
for i in {1..60}; do
    OUTPUT=$(aws ec2 get-console-output --instance-id "$INSTANCE_ID" --latest --query Output --output text 2>/dev/null || true)
    if echo "$OUTPUT" | grep -q "ATTESTATION END"; then
        echo "$OUTPUT"
        exit 0
    fi
    sleep 2
done

echo "Timeout waiting for attestation. Last output:"
aws ec2 get-console-output --instance-id "$INSTANCE_ID" --latest --query Output --output text
