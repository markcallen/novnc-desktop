#!/usr/bin/env bash
# infra-up-tls.sh — provision EC2 and create a random Route53 hostname for
# Let's Encrypt TLS using smoke.markcallen.dev as the parent zone.
#
# Usage:
#   pnpm infra:up:tls
#
# Terraform creates a random subdomain (e.g. a1b2c3d4.smoke.markcallen.dev),
# creates an A record pointing to the instance public IP, and outputs the FQDN.
# The hostname is saved to state.json so provision scripts automatically pass
# use_certbot=true and tls_domain to Ansible.
#
# terraform destroy (pnpm infra:down) removes the A record automatically.
#
# Prerequisites:
#   - AWS credentials with route53:ChangeResourceRecordSets,
#     route53:ListHostedZones, and route53:GetChange on the
#     smoke.markcallen.dev hosted zone.
#   - Ports 80 and 443 must be open in terraform.tfvars (http_cidr/https_cidr).

set -euo pipefail

TLS_ZONE="smoke.markcallen.dev"
LABEL="infra:up:tls"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/smoke/ec2"
KEYS_DIR="$REPO_ROOT/.smoke-keys"
STATE_DIR="$REPO_ROOT/.smoke-state"
ARTIFACTS_DIR="$REPO_ROOT/.smoke-artifacts"
STATE_FILE="$STATE_DIR/state.json"
SSH_KEY_PATH="$KEYS_DIR/smoke.pem"

VNC_USER="${VNC_USER:-ubuntu}"

mkdir -p "$KEYS_DIR" "$STATE_DIR" "$ARTIFACTS_DIR"

# ---------------------------------------------------------------------------
# 0. Preflight — verify Route53 hosted zone exists in this AWS account
# ---------------------------------------------------------------------------
if aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${TLS_ZONE}.'].[Id,Name]" \
  --output text | grep -q .; then
  echo "[$LABEL] Verified Route53 hosted zone: ${TLS_ZONE}."
else
  echo "[$LABEL] ERROR: Route53 hosted zone not found: ${TLS_ZONE}." >&2
  echo "[$LABEL] Run: bash smoke/scripts/setup-certbot-route53.sh --zone ${TLS_ZONE}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Terraform — create EC2, SSH key, and Route53 A record
# ---------------------------------------------------------------------------
echo "[$LABEL] Initializing Terraform..."
cd "$TF_DIR"
terraform init -input=false

echo "[$LABEL] Applying Terraform with tls_zone=$TLS_ZONE..."
terraform apply -auto-approve -input=false \
  -var "tls_zone=$TLS_ZONE"

PUBLIC_IP=$(terraform output -raw public_ip)
PUBLIC_DNS=$(terraform output -raw public_dns)
TLS_HOSTNAME=$(terraform output -raw tls_hostname)

echo "[$LABEL] Instance ready:  $PUBLIC_IP ($PUBLIC_DNS)"
echo "[$LABEL] TLS hostname:    $TLS_HOSTNAME"

# ---------------------------------------------------------------------------
# 2. Wait for SSH to become available
# ---------------------------------------------------------------------------
echo "[$LABEL] Waiting for SSH on $PUBLIC_IP..."
attempt=0
while true; do
  attempt=$(( attempt + 1 ))
  if ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      -i "$SSH_KEY_PATH" \
      "$VNC_USER@$PUBLIC_IP" true 2>/dev/null; then
    echo "[$LABEL] SSH is ready."
    break
  fi
  if [[ $attempt -ge 30 ]]; then
    echo "[$LABEL] ERROR: SSH did not become ready after 5 minutes." >&2
    exit 1
  fi
  echo "[$LABEL] Attempt $attempt/30 — retrying in 10s..."
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
  "sshKeyPath": "$SSH_KEY_PATH",
  "tlsDomain": "$TLS_HOSTNAME",
  "tlsZone": "$TLS_ZONE"
}
EOF

echo "[$LABEL] State saved to $STATE_FILE"
echo ""
echo "Next: run a provision script to install a desktop environment:"
echo "  pnpm provision:openbox"
echo "  pnpm provision:elementary"
echo ""
echo "Ansible will automatically use certbot to obtain a Let's Encrypt"
echo "certificate for $TLS_HOSTNAME."
