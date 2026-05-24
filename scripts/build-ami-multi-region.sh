#!/usr/bin/env bash
# Build noVNC AMIs across a fixed region set, using one primary-region build
# with AMI copies to the additional regions.
#
# Regions: us-east-1, us-east-2, us-west-2
#
# Modes:
#   --public  Build public AMIs, but fail when a region has >=4 matching public AMIs.
#   --private Build private AMIs in all regions (single build + copy).
#
# Optional env vars:
#   AMI_NAME_PREFIX   (default: novnc-desktop-ubuntu-24.04)
#   PUBLIC_LIMIT      (default: 4)
#   AMI_ENVIRONMENT   (default: production for --public, test for --private)
#   and any vars consumed by packer.pkr.hcl (INSTANCE_TYPE, NOVNC_HTTP_PORT, NOVNC_HTTPS_PORT, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKER_TEMPLATE="$REPO_ROOT/packer.pkr.hcl"
PRIMARY_REGION="us-east-1"
REGIONS=("us-east-1" "us-east-2" "us-west-2")
AMI_NAME_PREFIX="${AMI_NAME_PREFIX:-novnc-desktop-ubuntu-24.04}"
PUBLIC_LIMIT="${PUBLIC_LIMIT:-4}"
MODE="public"
DRY_RUN="false"

usage() {
  cat <<'USAGE'
Usage: bash scripts/build-ami-multi-region.sh [--public|--private] [--dry-run]

Options:
  --public    Build public AMIs (default). Fails if any region has >= PUBLIC_LIMIT existing matching public AMIs.
  --private   Build private AMIs in all regions.
  --dry-run   Print what would run without building.
  --help      Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public)
      MODE="public"
      shift
      ;;
    --private)
      MODE="private"
      shift
      ;;
    --dry-run|-n)
      DRY_RUN="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$PACKER_TEMPLATE" ]]; then
  echo "ERROR: packer template not found: $PACKER_TEMPLATE" >&2
  exit 1
fi

if ! [[ "$PUBLIC_LIMIT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: PUBLIC_LIMIT must be a non-negative integer (got: $PUBLIC_LIMIT)" >&2
  exit 1
fi

if [[ "$MODE" == "public" ]]; then
  AMI_PUBLIC_VALUE="true"
  AMI_ENVIRONMENT_VALUE="${AMI_ENVIRONMENT:-production}"
else
  AMI_PUBLIC_VALUE="false"
  AMI_ENVIRONMENT_VALUE="${AMI_ENVIRONMENT:-test}"
fi

count_matching_public_amis() {
  local region="$1"

  aws ec2 describe-images \
    --region "$region" \
    --owners self \
    --filters \
      "Name=tag:Project,Values=novnc-desktop" \
      "Name=tag:Environment,Values=$AMI_ENVIRONMENT_VALUE" \
      "Name=state,Values=available" \
      "Name=name,Values=${AMI_NAME_PREFIX}-*" \
    --query 'length(Images[?Public==`true`])' \
    --output text
}

for region in "${REGIONS[@]}"; do
  echo ""
  echo "=== Region: $region ==="

  if [[ "$MODE" == "public" ]]; then
    public_count="$(count_matching_public_amis "$region")"
    echo "Public AMIs matching prefix '${AMI_NAME_PREFIX}-*': $public_count"

    if (( public_count >= PUBLIC_LIMIT )); then
      echo "ERROR: $region already has ${public_count} matching public AMIs (limit=${PUBLIC_LIMIT})." >&2
      echo "Run the AMI cleanup script, then retry this command." >&2
      exit 1
    fi
  fi

done

TARGET_REGIONS=()
for region in "${REGIONS[@]}"; do
  if [[ "$region" != "$PRIMARY_REGION" ]]; then
    TARGET_REGIONS+=("\"$region\"")
  fi
done
AMI_REGIONS_HCL="[$(IFS=,; echo "${TARGET_REGIONS[*]}")]"

INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
USE_CERTBOT="${USE_CERTBOT:-false}"
NOVNC_HTTP_PORT="${NOVNC_HTTP_PORT:-80}"
NOVNC_HTTPS_PORT="${NOVNC_HTTPS_PORT:-443}"
GIT_SHA="${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
APP_VERSION="${APP_VERSION:-$(node -p "require('./package.json').version" 2>/dev/null || echo unknown)}"

PACKER_CMD=(
  packer build
  -var "aws_region=$PRIMARY_REGION"
  -var "ami_regions=$AMI_REGIONS_HCL"
  -var "instance_type=$INSTANCE_TYPE"
  -var "ami_name_prefix=$AMI_NAME_PREFIX"
  -var "use_certbot=$USE_CERTBOT"
  -var "ami_public=$AMI_PUBLIC_VALUE"
  -var "ami_environment=$AMI_ENVIRONMENT_VALUE"
  -var "git_sha=$GIT_SHA"
  -var "app_version=$APP_VERSION"
  -var "novnc_http_port=$NOVNC_HTTP_PORT"
  -var "novnc_https_port=$NOVNC_HTTPS_PORT"
  "$PACKER_TEMPLATE"
)

echo ""
echo "Primary build region: $PRIMARY_REGION"
echo "Copy target regions:  ${TARGET_REGIONS[*]//\"/}"
echo "Mode:                 $MODE"
echo "Public:               $AMI_PUBLIC_VALUE"
echo "Environment:          $AMI_ENVIRONMENT_VALUE"

if [[ "$DRY_RUN" == "true" ]]; then
  printf '[dry-run] '
  printf '%q ' "${PACKER_CMD[@]}"
  printf '\n'
else
  (cd "$REPO_ROOT" && "${PACKER_CMD[@]}")
fi

echo ""
echo "Done."
