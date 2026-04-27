#!/usr/bin/env bash
# infra-up-ubuntu22.sh — provision the EC2 smoke test server on Ubuntu 22.04 (Jammy).
#
# Usage:
#   pnpm infra:up:ubuntu22
#
# This script only handles infrastructure provisioning (Terraform + SSH readiness).
# Deepin requires Ubuntu 22.04; use this script instead of infra-up.sh before
# running provision-deepin.sh.
#
# To install a desktop environment, run one of the provision scripts afterwards:
#
#   bash smoke/scripts/provision-openbox.sh
#   bash smoke/scripts/provision-elementary.sh
#   bash smoke/scripts/provision-deepin.sh
#
# Terraform variables are read from smoke/ec2/terraform.tfvars.
# Copy smoke/ec2/terraform.tfvars.example to smoke/ec2/terraform.tfvars and
# fill in your values before running this script.
#
# Optional environment variables:
#   VNC_USER   SSH username on the EC2 instance (default: ubuntu).

set -euo pipefail

export TF_VAR_ubuntu_version="22.04"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/infra-up.sh"
