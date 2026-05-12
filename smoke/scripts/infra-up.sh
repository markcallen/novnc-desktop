#!/usr/bin/env bash
# infra-up.sh — provision the EC2 smoke test server with Terraform.
#
# Usage:
#   pnpm infra:up
#
# This script only handles infrastructure provisioning (Terraform + SSH readiness).
# To install a desktop environment, run one of the provision scripts afterwards:
#
#   bash smoke/scripts/provision-openbox.sh
#   bash smoke/scripts/provision-elementary.sh
#
# No SSH key configuration needed. Terraform generates a dedicated key pair,
# writes the private key to .smoke-keys/smoke.pem, and registers the public
# key with AWS automatically.
#
# Terraform variables are read from smoke/ec2/terraform.tfvars.
# Copy smoke/ec2/terraform.tfvars.example to smoke/ec2/terraform.tfvars and
# fill in your values before running this script.
#
# Optional environment variables:
#   VNC_USER   SSH username on the EC2 instance (default: ubuntu).

set -euo pipefail

VNC_USER="${VNC_USER:-ubuntu}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/smoke/ec2"
KEYS_DIR="$REPO_ROOT/.smoke-keys"
STATE_DIR="$REPO_ROOT/.smoke-state"
ARTIFACTS_DIR="$REPO_ROOT/.smoke-artifacts"
STATE_FILE="$STATE_DIR/state.json"
SSH_KEY_PATH="$KEYS_DIR/smoke.pem"

# Create local directories that Terraform's local_file resource requires.
mkdir -p "$KEYS_DIR" "$STATE_DIR" "$ARTIFACTS_DIR"

# ---------------------------------------------------------------------------
# 1. Terraform — create EC2 instance and generate SSH key pair
# ---------------------------------------------------------------------------
echo "[infra:up] Initializing Terraform..."
cd "$TF_DIR"
terraform init -input=false

echo "[infra:up] Applying Terraform (this takes ~1 min)..."
terraform apply -auto-approve -input=false

PUBLIC_IP=$(terraform output -raw public_ip)
PUBLIC_DNS=$(terraform output -raw public_dns)
echo "[infra:up] Instance ready: $PUBLIC_IP ($PUBLIC_DNS)"
echo "[infra:up] SSH key written to $SSH_KEY_PATH"

# ---------------------------------------------------------------------------
# 2. Wait for SSH to become available
# ---------------------------------------------------------------------------
echo "[infra:up] Waiting for SSH on $PUBLIC_IP..."
attempt=0
while true; do
  attempt=$(( attempt + 1 ))
  if ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      -i "$SSH_KEY_PATH" \
      "$VNC_USER@$PUBLIC_IP" true 2>/dev/null; then
    echo "[infra:up] SSH is ready."
    break
  fi
  if [[ $attempt -ge 30 ]]; then
    echo "[infra:up] ERROR: SSH did not become ready after 5 minutes." >&2
    exit 1
  fi
  echo "[infra:up] Attempt $attempt/30 — retrying in 10s..."
  sleep 10
done

# ---------------------------------------------------------------------------
# 3. Save infrastructure state
# ---------------------------------------------------------------------------
cat > "$STATE_FILE" <<EOF
{
  "publicIp": "$PUBLIC_IP",
  "publicDns": "$PUBLIC_DNS",
  "vncUser": "$VNC_USER",
  "sshKeyPath": "$SSH_KEY_PATH"
}
EOF

echo ""
echo "[infra:up] State saved to $STATE_FILE"
echo ""
echo "Next: run a provision script to install a desktop environment:"
echo "  bash smoke/scripts/provision-openbox.sh"
echo "  bash smoke/scripts/provision-elementary.sh"
echo "  bash smoke/scripts/provision-elementary-custom-ports.sh"
