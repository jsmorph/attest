#!/bin/bash
set -euo pipefail

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

AMI_ID="${1:-}"
SCRIPT_FILE="${2:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-c5.xlarge}"
IAM_INSTANCE_PROFILE="${IAM_INSTANCE_PROFILE:-}"
ROOT_VOLUME_SIZE_GB="${ROOT_VOLUME_SIZE_GB:-}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-240}"
EXEC_ENV_VARS="${EXEC_ENV_VARS:-}"

if [[ -z "$AMI_ID" || -z "$SCRIPT_FILE" ]]; then
    echo "Usage: $0 <ami-id> <script-file>" >&2
    exit 1
fi

if [[ ! -f "$SCRIPT_FILE" ]]; then
    echo "Error: $SCRIPT_FILE not found" >&2
    exit 1
fi

TMP_USER_DATA=""
USER_DATA_FILE="$SCRIPT_FILE"
INSTANCE_ID=""

cleanup() {
    if [[ -n "$INSTANCE_ID" ]]; then
        echo "Terminating instance $INSTANCE_ID"
        aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
    fi
    if [[ -n "$TMP_USER_DATA" ]]; then
        rm -f "$TMP_USER_DATA"
    fi
}
trap cleanup EXIT

shell_quote() {
    local value="$1"
    printf "'"
    printf '%s' "$value" | sed "s/'/'\\\\''/g"
    printf "'"
}

if [[ -n "$EXEC_ENV_VARS" ]]; then
    TMP_USER_DATA="$(mktemp)"
    {
        printf '%s\n' '#!/bin/sh'
        for name in ${EXEC_ENV_VARS//,/ }; do
            if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                echo "Error: invalid EXEC_ENV_VARS name: $name" >&2
                exit 1
            fi
            if [[ -z "${!name+x}" ]]; then
                echo "Error: EXEC_ENV_VARS includes unset variable: $name" >&2
                exit 1
            fi
            value="${!name}"
            if [[ "$value" == *$'\n'* ]]; then
                echo "Error: EXEC_ENV_VARS value contains a newline: $name" >&2
                exit 1
            fi
            printf 'export %s=' "$name"
            shell_quote "$value"
            printf '\n'
        done
        tail -n +2 "$SCRIPT_FILE"
    } > "$TMP_USER_DATA"
    chmod 600 "$TMP_USER_DATA"
    USER_DATA_FILE="$TMP_USER_DATA"
fi

echo "Launching instance with AMI $AMI_ID and user-data from $SCRIPT_FILE"
INSTANCE_PROFILE_ARGS=()
if [[ -n "$IAM_INSTANCE_PROFILE" ]]; then
    if [[ "$IAM_INSTANCE_PROFILE" == arn:* ]]; then
        INSTANCE_PROFILE_ARGS=(--iam-instance-profile "Arn=$IAM_INSTANCE_PROFILE")
    else
        INSTANCE_PROFILE_ARGS=(--iam-instance-profile "Name=$IAM_INSTANCE_PROFILE")
    fi
fi

ROOT_VOLUME_ARGS=()
if [[ -n "$ROOT_VOLUME_SIZE_GB" ]]; then
    ROOT_VOLUME_ARGS=(--block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$ROOT_VOLUME_SIZE_GB,DeleteOnTermination=true}")
fi

INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --user-data "file://$USER_DATA_FILE" \
    "${INSTANCE_PROFILE_ARGS[@]}" \
    "${ROOT_VOLUME_ARGS[@]}" \
    --count 1 \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance: $INSTANCE_ID"

echo "Waiting for instance to run"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

echo "Polling console output"
for ((i = 1; i <= POLL_ATTEMPTS; i++)); do
    OUTPUT=$(aws ec2 get-console-output --instance-id "$INSTANCE_ID" --latest --query Output --output text 2>/dev/null || true)
    APP_OUTPUT=$(printf '%s\n' "$OUTPUT" | grep 'app\[' | sed 's/.*app\[[0-9]*\]: //' || true)
    if printf '%s\n' "$APP_OUTPUT" | grep -q "ATTESTATION END"; then
        echo "$OUTPUT" > execout.txt
        printf '%s\n' "$APP_OUTPUT"
        exit 0
    fi
    if printf '%s\n' "$APP_OUTPUT" | grep -qE '(^|[[:space:]])([Ee]rror|ERROR)(:|[[:space:]])'; then
        echo "$OUTPUT" > execout.txt
        printf '%s\n' "$APP_OUTPUT"
        exit 1
    fi
    sleep 2
done

echo "Timeout waiting for output." >&2
OUTPUT=$(aws ec2 get-console-output --instance-id "$INSTANCE_ID" --latest --query Output --output text)
echo "$OUTPUT" > execout.txt
grep 'app\[' execout.txt | sed 's/.*app\[[0-9]*\]: //'
exit 1
