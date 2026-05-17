#!/usr/bin/env bash
# infra-ami.sh — launch EC2 instance from novnc-desktop AMI
#
# Usage:
#   pnpm infra:ami [AMI_ID]
#
# This script launches a pre-built novnc-desktop AMI directly without provisioning.
# Since the AMI already has the full stack installed, you can skip to testing:
#
#   pnpm infra:ami ami-0613b782c7ff5544d
#   pnpm test
#
# If no AMI_ID is provided, the script will find the most recent novnc-desktop AMI
# tagged with Environment=test and Project=novnc-desktop.
#
# The instance will be configured with security groups and tagging matching
# the smoke test environment (from terraform.tfvars).
#
# Optional environment variables:
#   VNC_USER       SSH username on the EC2 instance (default: ubuntu).
#   AWS_REGION     AWS region (default: read from terraform.tfvars).
#   INSTANCE_TYPE  EC2 instance type (default: t3.small).

set -euo pipefail

VNC_USER="${VNC_USER:-ubuntu}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEYS_DIR="$REPO_ROOT/.smoke-keys"
STATE_DIR="$REPO_ROOT/.smoke-state"
ARTIFACTS_DIR="$REPO_ROOT/.smoke-artifacts"
STATE_FILE="$STATE_DIR/state.json"
SSH_KEY_PATH="$KEYS_DIR/smoke.pem"
TF_DIR="$REPO_ROOT/smoke/ec2"

# Create local directories
mkdir -p "$KEYS_DIR" "$STATE_DIR" "$ARTIFACTS_DIR"

# Read terraform.tfvars for configuration
if [[ ! -f "$TF_DIR/terraform.tfvars" ]]; then
  echo "ERROR: $TF_DIR/terraform.tfvars not found." >&2
  echo "Copy terraform.tfvars.example to terraform.tfvars and configure it." >&2
  exit 1
fi

# Source terraform.tfvars as shell syntax (hcl format is compatible with shell for simple cases)
# Extract key variables using terraform console or parsing
AWS_REGION=$(grep 'aws_region' "$TF_DIR/terraform.tfvars" | grep -o '"[^"]*"' | head -1 | tr -d '"')
STACK_NAME=$(grep 'stack_name' "$TF_DIR/terraform.tfvars" | grep -o '"[^"]*"' | head -1 | tr -d '"')
NAME_PREFIX=$(grep 'name_prefix' "$TF_DIR/terraform.tfvars" | grep -o '"[^"]*"' | head -1 | tr -d '"' || echo "novnc-smoke")
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
SSH_CIDR=$(grep 'ssh_cidr' "$TF_DIR/terraform.tfvars" | grep -o '"[^"]*"' | head -1 | tr -d '"')
HTTP_CIDR=$(grep 'http_cidr' "$TF_DIR/terraform.tfvars" | grep -o '"[^"]*"' | head -1 | tr -d '"')
HTTPS_CIDR=$(grep 'https_cidr' "$TF_DIR/terraform.tfvars" | grep -o '"[^"]*"' | head -1 | tr -d '"')

if [[ -z "$AWS_REGION" || -z "$STACK_NAME" ]]; then
  echo "ERROR: Could not read aws_region or stack_name from terraform.tfvars" >&2
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
    echo "Build an AMI first with: pnpm run build-ami.sh" >&2
    exit 1
  fi
fi

echo "[infra:ami] Using AMI: $AMI_ID"

# ---------------------------------------------------------------------------
# 1. Generate SSH key pair (if not already present)
# ---------------------------------------------------------------------------
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "[infra:ami] Generating SSH key pair..."
  aws ec2 create-key-pair \
    --key-name "${NAME_PREFIX}-${STACK_NAME}" \
    --region "$AWS_REGION" \
    --query 'KeyMaterial' \
    --output text > "$SSH_KEY_PATH"
  chmod 600 "$SSH_KEY_PATH"
  echo "[infra:ami] SSH key written to $SSH_KEY_PATH"
else
  echo "[infra:ami] Using existing SSH key: $SSH_KEY_PATH"
fi

# ---------------------------------------------------------------------------
# 2. Create security group if needed
# ---------------------------------------------------------------------------
SG_NAME="${NAME_PREFIX}-${STACK_NAME}"
SG_ID=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  echo "[infra:ami] Creating security group $SG_NAME..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "novnc-desktop smoke test security group" \
    --region "$AWS_REGION" \
    --query 'GroupId' \
    --output text)

  # Allow SSH
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --region "$AWS_REGION" \
    --protocol tcp --port 22 --cidr "$SSH_CIDR" \
    2>/dev/null || true

  # Allow HTTP
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --region "$AWS_REGION" \
    --protocol tcp --port 80 --cidr "$HTTP_CIDR" \
    2>/dev/null || true

  # Allow HTTPS
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --region "$AWS_REGION" \
    --protocol tcp --port 443 --cidr "$HTTPS_CIDR" \
    2>/dev/null || true

  echo "[infra:ami] Security group created: $SG_ID"
else
  echo "[infra:ami] Using existing security group: $SG_ID"
fi

# ---------------------------------------------------------------------------
# 3. Launch EC2 instance from AMI
# ---------------------------------------------------------------------------
echo "[infra:ami] Launching EC2 instance from AMI $AMI_ID..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "${NAME_PREFIX}-${STACK_NAME}" \
  --security-group-ids "$SG_ID" \
  --region "$AWS_REGION" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_PREFIX}-${STACK_NAME}},{Key=Project,Value=novnc-desktop},{Key=Environment,Value=smoke},{Key=StackName,Value=${STACK_NAME}}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "[infra:ami] Instance launched: $INSTANCE_ID"

# ---------------------------------------------------------------------------
# 4. Wait for instance to get public IP and DNS
# ---------------------------------------------------------------------------
echo "[infra:ami] Waiting for instance to get public IP..."
attempt=0
while true; do
  attempt=$(( attempt + 1 ))
  INSTANCE_DATA=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$AWS_REGION" \
    --query 'Reservations[0].Instances[0].[PublicIpAddress,PublicDnsName,State.Name]' \
    --output text 2>/dev/null || echo "")

  PUBLIC_IP=$(echo "$INSTANCE_DATA" | awk '{print $1}')
  PUBLIC_DNS=$(echo "$INSTANCE_DATA" | awk '{print $2}')
  STATE=$(echo "$INSTANCE_DATA" | awk '{print $3}')

  if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "None" && "$STATE" == "running" ]]; then
    break
  fi

  if [[ $attempt -ge 30 ]]; then
    echo "[infra:ami] ERROR: Instance did not get public IP after 5 minutes." >&2
    exit 1
  fi

  echo "[infra:ami] Attempt $attempt/30 — state: ${STATE:-pending}, retrying in 10s..."
  sleep 10
done

echo "[infra:ami] Instance ready: $PUBLIC_IP ($PUBLIC_DNS)"

# ---------------------------------------------------------------------------
# 5. Wait for SSH to become available
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
# 6. Save infrastructure state
# ---------------------------------------------------------------------------
cat > "$STATE_FILE" <<EOF
{
  "instanceId": "$INSTANCE_ID",
  "publicIp": "$PUBLIC_IP",
  "publicDns": "$PUBLIC_DNS",
  "vncUser": "$VNC_USER",
  "sshKeyPath": "$SSH_KEY_PATH",
  "amiId": "$AMI_ID",
  "source": "infra:ami"
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
