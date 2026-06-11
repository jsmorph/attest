#!/bin/sh
set -eu

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

image_tar_s3="${IMAGE_TAR_S3:-s3://agentcourt-data/arbattest/images/arb-glue-poc.tar}"
: "${INPUT_PREFIX:?INPUT_PREFIX is required}"
input_prefix="${INPUT_PREFIX%/}"
output_root="${OUTPUT_ROOT:-s3://agentcourt-data/arbattest/aar-runs}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_id="${RUN_ID:-aar-ex01-$stamp}"
output_prefix="${OUTPUT_PREFIX:-$output_root/$run_id}"
work_root="${WORK_ROOT:-/var/lib/arbattest-aar}"
image_ref="${IMAGE_REF:-arb-glue:poc}"

mkdir -p "$work_root"

i=0
while ! docker info >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        echo "error: Docker daemon did not become ready" >&2
        exit 1
    fi
    sleep 1
done

image_tar="$work_root/image.tar"
aws s3 cp "$image_tar_s3" "$image_tar" --no-progress
set -- $(sha384sum "$image_tar")
image_tar_sha384="$1"
docker load -i "$image_tar"
image_id="$(docker image inspect "$image_ref" --format '{{.Id}}')"

if [ ! -e /dev/tpm0 ]; then
    echo "error: /dev/tpm0 is required for nitro-tpm-attest" >&2
    exit 1
fi

device_args="--device /dev/tpm0"
if [ -e /dev/tpmrm0 ]; then
    device_args="$device_args --device /dev/tpmrm0"
fi

docker run --rm \
    --network host \
    $device_args \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$work_root:$work_root" \
    -e AWS_DEFAULT_REGION \
    -e INPUT_PREFIX="$input_prefix" \
    -e OUTPUT_PREFIX="$output_prefix" \
    -e RUN_ID="$run_id" \
    -e ARB_GLUE_MODE=aar \
    -e ARB_GLUE_WORK_ROOT="$work_root" \
    -e ARB_GLUE_IMAGE_ID="$image_id" \
    -e ARB_GLUE_IMAGE_TAR_SHA384="$image_tar_sha384" \
    "$image_ref"

printf 'INPUT_PREFIX=%s\n' "$input_prefix"
printf 'OUTPUT_PREFIX=%s\n' "$output_prefix"
