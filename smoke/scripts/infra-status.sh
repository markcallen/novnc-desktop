#!/usr/bin/env bash
# infra-status.sh — show connection details for the running smoke test server.
#
# Usage:
#   pnpm infra:status

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$REPO_ROOT/.smoke-state/state.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "No smoke test server is running. Run 'pnpm infra:up' to provision one."
  exit 1
fi

PUBLIC_IP=$(jq -r '.publicIp' "$STATE_FILE")
PUBLIC_DNS=$(jq -r '.publicDns' "$STATE_FILE")
VNC_USER=$(jq -r '.vncUser' "$STATE_FILE")
SSH_KEY_PATH=$(jq -r '.sshKeyPath' "$STATE_FILE")
ACCESS_URL=$(jq -r '.accessUrl' "$STATE_FILE")
NOVNC_HTTP_PORT=$(jq -r '.novncHttpPort // 80' "$STATE_FILE")
NOVNC_HTTPS_PORT=$(jq -r '.novncHttpsPort // 443' "$STATE_FILE")

echo ""
echo "  Server      : $PUBLIC_IP ($PUBLIC_DNS)"
echo "  SSH         : ssh -i $SSH_KEY_PATH $VNC_USER@$PUBLIC_IP"
echo "  HTTP Port   : $NOVNC_HTTP_PORT"
echo "  HTTPS Port  : $NOVNC_HTTPS_PORT"
echo "  Desktop URL : $ACCESS_URL"
echo ""
