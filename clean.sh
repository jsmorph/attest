#!/bin/bash
# Clean up AWS resources from last 24 hours
set -euo pipefail

export AWS_DEFAULT_REGION=us-east-2
SINCE=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S)

echo "Deregistering AMIs..."
aws ec2 describe-images --owners self --query "Images[?CreationDate >= '$SINCE'].ImageId" --output text | tr '\t' '\n' | { grep . || true; } | while read ami; do
    echo "  $ami"
    aws ec2 deregister-image --image-id "$ami"
done

echo "Deleting snapshots..."
aws ec2 describe-snapshots --owner-ids self --query "Snapshots[?StartTime >= '$SINCE'].SnapshotId" --output text | tr '\t' '\n' | { grep . || true; } | while read snap; do
    echo "  $snap"
    aws ec2 delete-snapshot --snapshot-id "$snap"
done

echo "Terminating stopped instances..."
aws ec2 describe-instances --filters "Name=instance-state-name,Values=stopped" --query "Reservations[].Instances[?LaunchTime >= '$SINCE'].InstanceId" --output text | tr '\t' '\n' | { grep . || true; } | while read inst; do
    echo "  $inst"
    aws ec2 terminate-instances --instance-ids "$inst" > /dev/null
done

echo "Done."
