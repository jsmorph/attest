#!/bin/bash
# Clean up AWS resources from today
set -euo pipefail

export AWS_DEFAULT_REGION=us-east-2

echo "Deregistering AMIs..."
aws ec2 describe-images --owners self --query 'Images[?starts_with(CreationDate,`2026-01-01`)].ImageId' --output text | tr '\t' '\n' | grep . | while read ami; do
    echo "  $ami"
    aws ec2 deregister-image --image-id "$ami"
done

echo "Deleting snapshots..."
aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[?starts_with(StartTime,`2026-01-01`)].SnapshotId' --output text | tr '\t' '\n' | grep . | while read snap; do
    echo "  $snap"
    aws ec2 delete-snapshot --snapshot-id "$snap"
done

echo "Terminating stopped instances..."
aws ec2 describe-instances --filters "Name=instance-state-name,Values=stopped" --query 'Reservations[].Instances[?starts_with(LaunchTime,`2026-01-01`)].InstanceId' --output text | tr '\t' '\n' | grep . | while read inst; do
    echo "  $inst"
    aws ec2 terminate-instances --instance-ids "$inst" > /dev/null
done

echo "Done."
