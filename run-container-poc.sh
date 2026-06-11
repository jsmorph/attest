#!/bin/sh
set -eu

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-2}"

image_tar_s3="${IMAGE_TAR_S3:-s3://agentcourt-data/arbattest/images/arb-glue-poc.tar}"
output_root="${OUTPUT_ROOT:-s3://agentcourt-data/arbattest/container-poc}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_prefix="${OUTPUT_PREFIX:-$output_root/$stamp}"
work_root="${WORK_ROOT:-/var/lib/arbattest-container-poc}"
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
aws s3 cp "$image_tar_s3" "$image_tar"
image_tar_sha384="$(sha384sum "$image_tar" | awk '{print $1}')"
docker load -i "$image_tar"
image_id="$(docker image inspect "$image_ref" --format '{{.Id}}')"

docker run --rm \
    --network host \
    --device /dev/tpmrm0 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$work_root:$work_root" \
    -e AWS_DEFAULT_REGION \
    -e OUTPUT_PREFIX="$output_prefix" \
    -e RUN_ID="container-poc-$stamp" \
    -e ARB_GLUE_MODE=attest-only \
    -e ARB_GLUE_WORK_ROOT="$work_root" \
    -e ARB_GLUE_IMAGE_ID="$image_id" \
    -e ARB_GLUE_IMAGE_TAR_SHA384="$image_tar_sha384" \
    "$image_ref"

printf 'OUTPUT_PREFIX=%s\n' "$output_prefix"
