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
#   AMI_ENVIRONMENT  — Value for the Environment tag; use 'test' (default) so
#                      smoke/scripts/infra-ami.sh can discover the AMI, or
#                      'production' for public release builds
#   NOVNC_HTTP_PORT  — HTTP port nginx listens on (default: 80).
#                      Must be 80 when using Let's Encrypt (HTTP-01 challenge).
#                      Use 8080 only for self-signed / no-certbot builds.
#   NOVNC_HTTPS_PORT — HTTPS port nginx listens on (default: 443).
#                      Use 8443 for firewall-friendly or non-privileged deployments.
#
# Examples:
#   # Build private AMIs (no certbot, not public):
#   ./build-ami.sh
#
#   # Build public AMIs for distribution:
#   AMI_PUBLIC=true ./build-ami.sh
#
#   # Build AMIs on port 8443 (certbot-compatible — HTTP still on port 80):
#   NOVNC_HTTPS_PORT=8443 AMI_PUBLIC=true ./build-ami.sh
#
#   # Build AMIs on 8080/8443 (self-signed only — certbot requires port 80):
#   NOVNC_HTTP_PORT=8080 NOVNC_HTTPS_PORT=8443 AMI_PUBLIC=true ./build-ami.sh
#
#   # Build with custom prefix:
#   AMI_NAME_PREFIX=my-novnc AMI_PUBLIC=true ./build-ami.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
# AMI_NAME is kept for backwards compatibility with existing CI/CD pipelines.
# AMI_NAME_PREFIX takes precedence when set explicitly.
AMI_NAME_PREFIX="${AMI_NAME_PREFIX:-${AMI_NAME:-novnc-desktop-ubuntu-24.04}}"
USE_CERTBOT="${USE_CERTBOT:-false}"
AMI_PUBLIC="${AMI_PUBLIC:-false}"
AMI_ENVIRONMENT="${AMI_ENVIRONMENT:-test}"
NOVNC_HTTP_PORT="${NOVNC_HTTP_PORT:-80}"
NOVNC_HTTPS_PORT="${NOVNC_HTTPS_PORT:-443}"

echo "=========================================="
echo "Building noVNC Desktop AMIs"
echo "=========================================="
echo "Region:        $AWS_REGION"
echo "Instance Type: $INSTANCE_TYPE"
echo "AMI Name Prefix: $AMI_NAME_PREFIX"
echo "Variants:      openbox, elementary"
echo "Use Certbot:   $USE_CERTBOT"
echo "Public AMI:    $AMI_PUBLIC"
echo "Environment:   $AMI_ENVIRONMENT"
echo "HTTP Port:     $NOVNC_HTTP_PORT"
echo "HTTPS Port:    $NOVNC_HTTPS_PORT"
echo ""

# Check if Packer is installed
if ! command -v packer &> /dev/null; then
    echo "ERROR: Packer is not installed. Please install Packer first."
    echo "  https://www.packer.io/downloads"
    exit 1
fi

# Validate Packer configuration
echo "Validating Packer configuration..."
packer validate \
    -var "aws_region=$AWS_REGION" \
    -var "instance_type=$INSTANCE_TYPE" \
    -var "ami_name_prefix=$AMI_NAME_PREFIX" \
    -var "use_certbot=$USE_CERTBOT" \
    -var "ami_public=$AMI_PUBLIC" \
    -var "ami_environment=$AMI_ENVIRONMENT" \
    -var "novnc_http_port=$NOVNC_HTTP_PORT" \
    -var "novnc_https_port=$NOVNC_HTTPS_PORT" \
    packer.pkr.hcl

echo ""
echo "Configuration valid. Building AMIs..."
echo ""

# Format the configuration
packer fmt packer.pkr.hcl

# Build both AMI variants
packer build \
    -var "aws_region=$AWS_REGION" \
    -var "instance_type=$INSTANCE_TYPE" \
    -var "ami_name_prefix=$AMI_NAME_PREFIX" \
    -var "use_certbot=$USE_CERTBOT" \
    -var "ami_public=$AMI_PUBLIC" \
    -var "ami_environment=$AMI_ENVIRONMENT" \
    -var "novnc_http_port=$NOVNC_HTTP_PORT" \
    -var "novnc_https_port=$NOVNC_HTTPS_PORT" \
    packer.pkr.hcl

echo ""
echo "=========================================="
echo "Build complete!"
echo "AMI Name Prefix: $AMI_NAME_PREFIX"
echo "Variants built:  openbox, elementary"
echo "=========================================="
