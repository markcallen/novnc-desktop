#!/usr/bin/env bash
# infra-down.sh — destroy the EC2 smoke test server and clean up local state.
#
# Usage:
#   pnpm infra:down

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/smoke/ec2"
STATE_FILE="$REPO_ROOT/.smoke-state/state.json"

# ---------------------------------------------------------------------------
# 0. Remove Route53 A record if a TLS domain was configured
# ---------------------------------------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
  _TLS_DOMAIN=$(jq -r '.tlsDomain // ""' "$STATE_FILE")
  _PUBLIC_IP=$(jq -r '.publicIp // ""' "$STATE_FILE")

  if [[ -n "$_TLS_DOMAIN" && -n "$_PUBLIC_IP" ]]; then
    echo "[infra:down] Removing Route53 A record: $_TLS_DOMAIN → $_PUBLIC_IP..."
    _ZONE_ID=$(aws route53 list-hosted-zones \
      --query "HostedZones[?Name=='${_TLS_DOMAIN}.'].Id" \
      --output text | sed 's|/hostedzone/||')

    if [[ -n "$_ZONE_ID" ]]; then
      _CHANGE_ID=$(aws route53 change-resource-record-sets \
        --hosted-zone-id "$_ZONE_ID" \
        --change-batch "{
          \"Changes\": [{
            \"Action\": \"DELETE\",
            \"ResourceRecordSet\": {
              \"Name\": \"${_TLS_DOMAIN}.\",
              \"Type\": \"A\",
              \"TTL\": 60,
              \"ResourceRecords\": [{\"Value\": \"${_PUBLIC_IP}\"}]
            }
          }]
        }" \
        --query 'ChangeInfo.Id' \
        --output text | sed 's|/change/||' 2>/dev/null || true)

      if [[ -n "$_CHANGE_ID" ]]; then
        aws route53 wait resource-record-sets-changed --id "$_CHANGE_ID" 2>/dev/null || true
        echo "[infra:down] Route53 record removed."
      fi
    else
      echo "[infra:down] Warning: hosted zone for $_TLS_DOMAIN not found; skipping DNS cleanup."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 1. Terraform destroy
# ---------------------------------------------------------------------------
echo "[infra:down] Destroying Terraform resources..."
cd "$TF_DIR"
terraform destroy -auto-approve -input=false

# ---------------------------------------------------------------------------
# 2. Remove local state (access URL is now invalid)
# ---------------------------------------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
  rm "$STATE_FILE"
  echo "[infra:down] State file removed."
fi

echo "[infra:down] Done. EC2 instance and security group have been destroyed."
