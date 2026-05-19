#!/usr/bin/env bash
# infra-up-tls.sh — provision EC2 and configure Route53 for Let's Encrypt TLS.
#
# Usage:
#   pnpm infra:up:tls
#
# Runs infra-up.sh first (Terraform + SSH readiness), then upserts an A record
# for smoke.markcallen.dev pointing to the new instance's public IP. The TLS
# domain is saved to state.json so provision scripts pick it up automatically
# and pass use_certbot=true to Ansible.
#
# Prerequisites:
#   - AWS credentials with route53:ChangeResourceRecordSets,
#     route53:ListHostedZones, and route53:GetChange on the
#     smoke.markcallen.dev hosted zone.
#   - The smoke.markcallen.dev hosted zone must exist in the AWS account.
#   - Ports 80 and 443 must be open in terraform.tfvars (http_cidr / https_cidr).

set -euo pipefail

TLS_DOMAIN="smoke.markcallen.dev"
TTL=60
LABEL="infra:up:tls"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$REPO_ROOT/.smoke-state"
STATE_FILE="$STATE_DIR/state.json"

# ---------------------------------------------------------------------------
# 1. Standard EC2 provisioning
# ---------------------------------------------------------------------------
bash "$REPO_ROOT/smoke/scripts/infra-up.sh"

PUBLIC_IP=$(jq -r '.publicIp' "$STATE_FILE")

# ---------------------------------------------------------------------------
# 2. Locate the hosted zone
# ---------------------------------------------------------------------------
echo "[$LABEL] Looking up hosted zone for $TLS_DOMAIN..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${TLS_DOMAIN}.'].Id" \
  --output text | sed 's|/hostedzone/||')

if [[ -z "$HOSTED_ZONE_ID" ]]; then
  echo "[$LABEL] ERROR: No hosted zone found for $TLS_DOMAIN." >&2
  echo "[$LABEL] Create the zone in Route53 or check your AWS credentials." >&2
  exit 1
fi

echo "[$LABEL] Hosted zone: $HOSTED_ZONE_ID"

# ---------------------------------------------------------------------------
# 3. Upsert A record smoke.markcallen.dev → public IP
# ---------------------------------------------------------------------------
echo "[$LABEL] Upserting A record: $TLS_DOMAIN → $PUBLIC_IP (TTL ${TTL}s)..."
CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${TLS_DOMAIN}.\",
        \"Type\": \"A\",
        \"TTL\": ${TTL},
        \"ResourceRecords\": [{\"Value\": \"${PUBLIC_IP}\"}]
      }
    }]
  }" \
  --query 'ChangeInfo.Id' \
  --output text | sed 's|/change/||')

echo "[$LABEL] Waiting for Route53 change $CHANGE_ID to propagate..."
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
echo "[$LABEL] DNS record is INSYNC."

# ---------------------------------------------------------------------------
# 4. Update state with tlsDomain
# ---------------------------------------------------------------------------
VNC_USER=$(jq -r '.vncUser' "$STATE_FILE")
PUBLIC_DNS=$(jq -r '.publicDns' "$STATE_FILE")
SSH_KEY_PATH=$(jq -r '.sshKeyPath' "$STATE_FILE")

cat > "$STATE_FILE" <<EOF
{
  "publicIp": "$PUBLIC_IP",
  "publicDns": "$PUBLIC_DNS",
  "vncUser": "$VNC_USER",
  "sshKeyPath": "$SSH_KEY_PATH",
  "tlsDomain": "$TLS_DOMAIN"
}
EOF

echo "[$LABEL] State updated: tlsDomain=$TLS_DOMAIN"
echo ""
echo "Next: run a provision script to install a desktop environment:"
echo "  pnpm provision:openbox"
echo "  pnpm provision:elementary"
echo ""
echo "Ansible will automatically use certbot to obtain a Let's Encrypt"
echo "certificate for $TLS_DOMAIN."
