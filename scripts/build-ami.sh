#!/bin/bash
set -e

# Script to build the noVNC Desktop AMIs using Packer
# Builds both openbox and elementary variants in a single packer run.
#
# Environment variables:
#   AWS_REGION       — AWS region (default: us-east-1)
#   INSTANCE_TYPE    — EC2 instance type (default: t3.medium)
#   AMI_NAME_PREFIX  — Prefix for AMI names (default: novnc-desktop-ubuntu-24.04)
#                      AMI_NAME is accepted as a legacy alias when AMI_NAME_PREFIX is unset.
#   USE_CERTBOT      — Whether to run certbot at bake time; set true only for
#                      private AMIs where the domain is known at build time
#                      (default: false — recommended for public AMIs)
#   AMI_PUBLIC       — Make the resulting AMIs publicly launchable (default: false)
#   PUBLIC_AMI_LIMIT — Account public AMI quota for the target region
#                      (default: 5; set higher if AWS quota has been increased)
#   AMI_ENVIRONMENT  — Value for the Environment tag; use 'test' (default) so
#                      smoke/scripts/infra-ami.sh can discover the AMI, or
#                      'production' for public release builds
#   GIT_SHA          — Commit SHA tag value for the AMI/snapshots.
#                      Defaults to current `git rev-parse --short HEAD`.
#   APP_VERSION      — Version tag value for the AMI/snapshots.
#                      Defaults to `package.json` version.
#   NOVNC_HTTP_PORT  — HTTP port nginx listens on (default: 80).
#                      Must be 80 when using Let's Encrypt (HTTP-01 challenge).
#                      Use 8080 only for self-signed / no-certbot builds.
#   NOVNC_HTTPS_PORT — HTTPS port nginx listens on (default: 443).
#                      Use 8443 for firewall-friendly or non-privileged deployments.
#
# Examples:
#   # Build private AMIs (no certbot, not public):
#   ./scripts/build-ami.sh
#
#   # Preview the commands without executing:
#   ./scripts/build-ami.sh --dry-run
#
#   # Build public AMIs for distribution:
#   AMI_PUBLIC=true ./scripts/build-ami.sh
#
#   # Build AMIs on port 8443 (certbot-compatible — HTTP still on port 80):
#   NOVNC_HTTPS_PORT=8443 AMI_PUBLIC=true ./scripts/build-ami.sh
#
#   # Build AMIs on 8080/8443 (self-signed only — certbot requires port 80):
#   NOVNC_HTTP_PORT=8080 NOVNC_HTTPS_PORT=8443 AMI_PUBLIC=true ./scripts/build-ami.sh
#
#   # Build with custom prefix:
#   AMI_NAME_PREFIX=my-novnc AMI_PUBLIC=true ./scripts/build-ami.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

export LANG="${NOVNC_ANSIBLE_LOCALE:-en_US.utf8}"
export LC_ALL="${NOVNC_ANSIBLE_LOCALE:-en_US.utf8}"

DRY_RUN=false

usage() {
    cat <<'EOF'
Usage: ./scripts/build-ami.sh [--dry-run|-n] [--help|-h]

Options:
  --dry-run, -n   Print planned actions and packer commands without executing.
  --help, -h      Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
# AMI_NAME is kept for backwards compatibility with existing CI/CD pipelines.
# AMI_NAME_PREFIX takes precedence when set explicitly.
AMI_NAME_PREFIX="${AMI_NAME_PREFIX:-${AMI_NAME:-novnc-desktop-ubuntu-24.04}}"
USE_CERTBOT="${USE_CERTBOT:-false}"
AMI_PUBLIC="${AMI_PUBLIC:-false}"
PUBLIC_AMI_LIMIT="${PUBLIC_AMI_LIMIT:-5}"
AMI_ENVIRONMENT="${AMI_ENVIRONMENT:-test}"
NOVNC_HTTP_PORT="${NOVNC_HTTP_PORT:-80}"
NOVNC_HTTPS_PORT="${NOVNC_HTTPS_PORT:-443}"
GIT_SHA="${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
APP_VERSION="${APP_VERSION:-$(node -p "require('./package.json').version" 2>/dev/null || echo unknown)}"

echo "=========================================="
echo "Building noVNC Desktop AMIs"
echo "=========================================="
echo "Region:        $AWS_REGION"
echo "Instance Type: $INSTANCE_TYPE"
echo "AMI Name Prefix: $AMI_NAME_PREFIX"
echo "Variants:      openbox, elementary"
echo "Use Certbot:   $USE_CERTBOT"
echo "Public AMI:    $AMI_PUBLIC"
echo "Public AMI Limit: $PUBLIC_AMI_LIMIT"
echo "Environment:   $AMI_ENVIRONMENT"
echo "Git SHA:       $GIT_SHA"
echo "App Version:   $APP_VERSION"
echo "Dry Run:       $DRY_RUN"
echo "HTTP Port:     $NOVNC_HTTP_PORT"
echo "HTTPS Port:    $NOVNC_HTTPS_PORT"
echo ""

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[dry-run] '
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

check_ami_public_access_block() {
    local region="$1"
    local state
    local aws_error

    if ! command -v aws &> /dev/null; then
        echo "ERROR: aws CLI is required when AMI_PUBLIC=true."
        exit 1
    fi

    if ! state="$(aws ec2 get-image-block-public-access-state \
        --region "$region" \
        --query 'ImageBlockPublicAccessState' \
        --output text 2>&1)"; then
        aws_error="$state"
        echo "ERROR: Unable to read AMI block public access state for region '$region'."
        echo "AWS CLI output:"
        echo "$aws_error"
        echo "Verify AWS credentials, permissions (ec2:GetImageBlockPublicAccessState), and awscli version."
        exit 1
    fi

    if [[ "$state" != "unblocked" ]]; then
        echo "ERROR: AMI public sharing is blocked in region '$region' for this account."
        echo "Current ImageBlockPublicAccessState: $state"
        echo "AMI_PUBLIC=true cannot succeed until this is disabled."
        echo ""
        echo "To disable it in this region, run:"
        echo "  aws ec2 disable-image-block-public-access --region $region"
        echo ""
        echo "Or build private AMIs by setting:"
        echo "  AMI_PUBLIC=false"
        exit 1
    fi
}

count_public_amis() {
    local region="$1"

    aws ec2 describe-images \
        --region "$region" \
        --owners self \
        --query 'length(Images[?Public==`true`])' \
        --output text
}

check_public_ami_quota_room() {
    local region="$1"
    local planned_public_amis="$2"
    local public_count
    local remaining
    local aws_error

    if ! [[ "$PUBLIC_AMI_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "ERROR: PUBLIC_AMI_LIMIT must be a non-negative integer. Got: $PUBLIC_AMI_LIMIT" >&2
        exit 1
    fi

    if ! public_count="$(count_public_amis "$region" 2>&1)"; then
        aws_error="$public_count"
        echo "ERROR: Unable to count existing public AMIs in region '$region'."
        echo "AWS CLI output:"
        echo "$aws_error"
        echo "Verify AWS credentials and permissions (ec2:DescribeImages)."
        exit 1
    fi

    if ! [[ "$public_count" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Unexpected public AMI count from AWS: $public_count" >&2
        exit 1
    fi

    remaining=$(( PUBLIC_AMI_LIMIT - public_count ))

    echo "Public AMIs in $region: $public_count / $PUBLIC_AMI_LIMIT"
    echo "Public AMIs this build would create: $planned_public_amis"

    if (( remaining < planned_public_amis )); then
        echo ""
        echo "ERROR: Not enough public AMI quota remains in region '$region'."
        echo "Current public AMIs: $public_count"
        echo "Configured public AMI limit: $PUBLIC_AMI_LIMIT"
        echo "Remaining slots: $remaining"
        echo "Required slots for this build: $planned_public_amis"
        echo ""
        echo "Clean up unused public AMIs first:"
        echo "  ./scripts/cleanup-amis.sh --environment production --keep 2 --dry-run"
        echo "  ./scripts/cleanup-amis.sh --environment production --keep 2 --yes"
        echo ""
        echo "Or build private AMIs by setting:"
        echo "  AMI_PUBLIC=false"
        echo ""
        echo "If AWS has raised your quota, set:"
        echo "  PUBLIC_AMI_LIMIT=<new-limit>"
        exit 1
    fi
}

# Check if Packer is installed
if ! command -v packer &> /dev/null; then
    echo "ERROR: Packer is not installed. Please install Packer first."
    echo "  https://www.packer.io/downloads"
    exit 1
fi

if [[ "$AMI_PUBLIC" == "true" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "Dry run: would check AMI block public access state in region '$AWS_REGION'."
        echo "Dry run: would check public AMI quota room for 2 new public AMIs in region '$AWS_REGION'."
    else
        echo "Checking AMI block public access state..."
        check_ami_public_access_block "$AWS_REGION"
        echo "Checking public AMI quota room..."
        check_public_ami_quota_room "$AWS_REGION" 2
    fi
fi

# Validate Packer configuration
echo "Validating Packer configuration..."
run_cmd packer validate \
    -var "aws_region=$AWS_REGION" \
    -var "instance_type=$INSTANCE_TYPE" \
    -var "ami_name_prefix=$AMI_NAME_PREFIX" \
    -var "use_certbot=$USE_CERTBOT" \
    -var "ami_public=$AMI_PUBLIC" \
    -var "ami_environment=$AMI_ENVIRONMENT" \
    -var "git_sha=$GIT_SHA" \
    -var "app_version=$APP_VERSION" \
    -var "novnc_http_port=$NOVNC_HTTP_PORT" \
    -var "novnc_https_port=$NOVNC_HTTPS_PORT" \
    packer.pkr.hcl

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run: validation command prepared. Build command preview follows..."
else
    echo "Configuration valid. Building AMIs..."
fi
echo ""

# Format the configuration
run_cmd packer fmt packer.pkr.hcl

# Build both AMI variants
run_cmd packer build \
    -var "aws_region=$AWS_REGION" \
    -var "instance_type=$INSTANCE_TYPE" \
    -var "ami_name_prefix=$AMI_NAME_PREFIX" \
    -var "use_certbot=$USE_CERTBOT" \
    -var "ami_public=$AMI_PUBLIC" \
    -var "ami_environment=$AMI_ENVIRONMENT" \
    -var "git_sha=$GIT_SHA" \
    -var "app_version=$APP_VERSION" \
    -var "novnc_http_port=$NOVNC_HTTP_PORT" \
    -var "novnc_https_port=$NOVNC_HTTPS_PORT" \
    packer.pkr.hcl

echo ""
echo "=========================================="
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run complete! No AMIs were built."
else
    echo "Build complete!"
fi
echo "AMI Name Prefix: $AMI_NAME_PREFIX"
echo "Variants built:  openbox, elementary"
echo "=========================================="
