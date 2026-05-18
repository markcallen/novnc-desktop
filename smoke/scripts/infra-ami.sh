#!/usr/bin/env bash
# infra-ami.sh — launch EC2 instance from novnc-desktop AMI using Terraform
#
# Usage:
#   pnpm infra:ami [AMI_ID]
#
# This script launches a pre-built novnc-desktop AMI using the same Terraform
# configuration as infra:up, just with a pre-built AMI instead of vanilla Ubuntu.
# Since the AMI already has the full stack installed, you can skip to testing:
#
#   pnpm infra:ami ami-0613b782c7ff5544d
#   pnpm test
#
# If no AMI_ID is provided, the script will find the most recent novnc-desktop AMI
# tagged with Environment=test and Project=novnc-desktop.
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

# Create local directories
mkdir -p "$KEYS_DIR" "$STATE_DIR" "$ARTIFACTS_DIR"

# Read terraform.tfvars for configuration
if [[ ! -f "$TF_DIR/terraform.tfvars" ]]; then
  echo "ERROR: $TF_DIR/terraform.tfvars not found." >&2
  echo "Copy terraform.tfvars.example to terraform.tfvars and configure it." >&2
  exit 1
fi

# Extract AWS_REGION from terraform.tfvars
AWS_REGION=$(grep 'aws_region' "$TF_DIR/terraform.tfvars" | grep -o '"[^"]*"' | head -1 | tr -d '"')
if [[ -z "$AWS_REGION" ]]; then
  echo "ERROR: Could not read aws_region from terraform.tfvars" >&2
  exit 1
fi

# Use provided AMI_ID or find the most recent novnc-desktop AMI
AMI_ID="${1:-}"
if [[ -z "$AMI_ID" ]]; then
  echo "[infra:ami] Finding most recent novnc-desktop AMI in $AWS_REGION..."
  AMI_ID=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners self \
    --filters "Name=tag:Environment,Values=test" \
              "Name=tag:Project,Values=novnc-desktop" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

  if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "ERROR: No novnc-desktop AMI found with Environment=test and Project=novnc-desktop" >&2
    echo "Build an AMI first with: ./build-ami.sh" >&2
    exit 1
  fi
fi

echo "[infra:ami] Using AMI: $AMI_ID"

# ---------------------------------------------------------------------------
# Use Terraform to launch the instance from the AMI
# ---------------------------------------------------------------------------
echo "[infra:ami] Initializing Terraform..."
cd "$TF_DIR"
terraform init -input=false

echo "[infra:ami] Applying Terraform with AMI $AMI_ID..."
terraform apply -auto-approve -input=false -var "ami_id=$AMI_ID"

PUBLIC_IP=$(terraform output -raw public_ip)
PUBLIC_DNS=$(terraform output -raw public_dns)
echo "[infra:ami] Instance ready: $PUBLIC_IP ($PUBLIC_DNS)"
echo "[infra:ami] SSH key written to $SSH_KEY_PATH"

# ---------------------------------------------------------------------------
# Wait for SSH to become available
# ---------------------------------------------------------------------------
echo "[infra:ami] Waiting for SSH on $PUBLIC_IP..."
attempt=0
while true; do
  attempt=$(( attempt + 1 ))
  if ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      -i "$SSH_KEY_PATH" \
      "$VNC_USER@$PUBLIC_IP" true 2>/dev/null; then
    echo "[infra:ami] SSH is ready."
    break
  fi
  if [[ $attempt -ge 30 ]]; then
    echo "[infra:ami] ERROR: SSH did not become ready after 5 minutes." >&2
    exit 1
  fi
  echo "[infra:ami] Attempt $attempt/30 — retrying in 10s..."
  sleep 10
done

# ---------------------------------------------------------------------------
# Save infrastructure state
# ---------------------------------------------------------------------------
cat > "$STATE_FILE" <<EOF
{
  "publicIp": "$PUBLIC_IP",
  "publicDns": "$PUBLIC_DNS",
  "vncUser": "$VNC_USER",
  "sshKeyPath": "$SSH_KEY_PATH",
  "amiId": "$AMI_ID"
}
EOF

echo ""
echo "[infra:ami] State saved to $STATE_FILE"
echo ""
echo "Next: run the smoke tests:"
echo "  pnpm test"
echo ""
echo "When done, clean up with:"
echo "  pnpm infra:down"
