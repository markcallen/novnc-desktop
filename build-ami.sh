#!/bin/bash
set -e

# Script to build the noVNC Desktop AMI using Packer
# This script sets up the environment and runs Packer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"
AMI_NAME="${AMI_NAME:-novnc-desktop-ubuntu-24.04-$(date +%s)}"

echo "=========================================="
echo "Building noVNC Desktop AMI"
echo "=========================================="
echo "Region:        $AWS_REGION"
echo "Instance Type: $INSTANCE_TYPE"
echo "AMI Name:      $AMI_NAME"
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
    -var "ami_name=$AMI_NAME" \
    packer.pkr.hcl

echo ""
echo "Configuration valid. Building AMI..."
echo ""

# Format the configuration (optional but recommended)
packer fmt packer.pkr.hcl

# Build the AMI
packer build \
    -var "aws_region=$AWS_REGION" \
    -var "instance_type=$INSTANCE_TYPE" \
    -var "ami_name=$AMI_NAME" \
    packer.pkr.hcl

echo ""
echo "=========================================="
echo "Build complete!"
echo "AMI Name: $AMI_NAME"
echo "=========================================="
