#!/usr/bin/env bash
# infra-up.sh — provision the EC2 smoke test server and save connection state.
#
# Usage:
#   pnpm infra:up
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
# 3. Ansible Galaxy dependencies
# ---------------------------------------------------------------------------
echo "[infra:up] Installing Ansible Galaxy requirements..."
cd "$REPO_ROOT"
ansible-galaxy install -r requirements.yml --force

# ---------------------------------------------------------------------------
# 4. Ansible — provision the desktop
# smoke_test_marker_enabled=true renders the bright-green xterm that the
# Playwright desktop test looks for on the canvas.
# ---------------------------------------------------------------------------
echo "[infra:up] Provisioning with Ansible (this takes ~5-10 min)..."
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook site.yml \
  -i "$PUBLIC_IP," \
  -u "$VNC_USER" \
  --private-key "$SSH_KEY_PATH" \
  -e "smoke_test_marker_enabled=true"

# ---------------------------------------------------------------------------
# 5. Fetch a time-limited desktop access URL
# ---------------------------------------------------------------------------
echo "[infra:up] Fetching desktop access URL..."
DESKTOP_URL_OUTPUT=$(
  ssh \
    -o StrictHostKeyChecking=no \
    -i "$SSH_KEY_PATH" \
    "$VNC_USER@$PUBLIC_IP" \
    desktop-url
)
ACCESS_URL=$(echo "$DESKTOP_URL_OUTPUT" | awk '/Desktop URL/{print $NF}')

if [[ -z "$ACCESS_URL" ]]; then
  echo "[infra:up] ERROR: Could not parse access URL from desktop-url output:" >&2
  echo "$DESKTOP_URL_OUTPUT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 6. Save state for the test runner
# ---------------------------------------------------------------------------
cat > "$STATE_FILE" <<EOF
{
  "publicIp": "$PUBLIC_IP",
  "publicDns": "$PUBLIC_DNS",
  "accessUrl": "$ACCESS_URL",
  "vncUser": "$VNC_USER",
  "sshKeyPath": "$SSH_KEY_PATH"
}
EOF

echo ""
echo "[infra:up] State saved to $STATE_FILE"
echo "[infra:up] Access URL: $ACCESS_URL"
echo ""
echo "Run 'pnpm test' to execute the smoke tests."
echo "Run 'pnpm infra:down' when you are done to destroy the instance."
