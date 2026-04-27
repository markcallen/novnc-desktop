#!/usr/bin/env bash
# _provision-common.sh — shared Ansible provisioning logic.
#
# Sourced by provision-*.sh scripts. Not intended to be run directly.
#
# Expected variables set by the caller before sourcing:
#   DESKTOP_TYPE   — desktop_type value passed to Ansible (openbox, elementary)
#
# Optional environment variables:
#   VNC_USER       — SSH username on the EC2 instance (default: ubuntu)

set -euo pipefail

VNC_USER="${VNC_USER:-ubuntu}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$REPO_ROOT/.smoke-state"
STATE_FILE="$STATE_DIR/state.json"
SSH_KEY_PATH="$REPO_ROOT/.smoke-keys/smoke.pem"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: No infrastructure state found at $STATE_FILE." >&2
  echo "Run 'pnpm infra:up' first to provision the EC2 instance." >&2
  exit 1
fi

PUBLIC_IP=$(jq -r '.publicIp' "$STATE_FILE")

# ---------------------------------------------------------------------------
# 1. Ansible Galaxy dependencies
# ---------------------------------------------------------------------------
echo "[provision:$DESKTOP_TYPE] Installing Ansible Galaxy requirements..."
cd "$REPO_ROOT"
ansible-galaxy install -r requirements.yml --force

# ---------------------------------------------------------------------------
# 2. Ansible — provision the desktop
# smoke_test_marker_enabled=true renders the bright-green xterm that the
# Playwright desktop test looks for on the canvas.
# ---------------------------------------------------------------------------
echo "[provision:$DESKTOP_TYPE] Provisioning with Ansible (this takes ~5-10 min)..."
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook site.yml \
  -i "$PUBLIC_IP," \
  -u "$VNC_USER" \
  --private-key "$SSH_KEY_PATH" \
  -e "desktop_type=$DESKTOP_TYPE smoke_test_marker_enabled=true"

# ---------------------------------------------------------------------------
# 3. Fetch a time-limited desktop access URL
# ---------------------------------------------------------------------------
echo "[provision:$DESKTOP_TYPE] Fetching desktop access URL..."
DESKTOP_URL_OUTPUT=$(
  ssh \
    -o StrictHostKeyChecking=no \
    -i "$SSH_KEY_PATH" \
    "$VNC_USER@$PUBLIC_IP" \
    desktop-url
)
ACCESS_URL=$(echo "$DESKTOP_URL_OUTPUT" | awk '/Desktop URL/{print $NF}')

if [[ -z "$ACCESS_URL" ]]; then
  echo "ERROR: Could not parse access URL from desktop-url output:" >&2
  echo "$DESKTOP_URL_OUTPUT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Update state with access URL and desktop type
# ---------------------------------------------------------------------------
PUBLIC_DNS=$(jq -r '.publicDns' "$STATE_FILE")

cat > "$STATE_FILE" <<EOF
{
  "publicIp": "$PUBLIC_IP",
  "publicDns": "$PUBLIC_DNS",
  "accessUrl": "$ACCESS_URL",
  "desktopType": "$DESKTOP_TYPE",
  "vncUser": "$VNC_USER",
  "sshKeyPath": "$SSH_KEY_PATH"
}
EOF

echo ""
echo "[provision:$DESKTOP_TYPE] State saved to $STATE_FILE"
echo "[provision:$DESKTOP_TYPE] Access URL: $ACCESS_URL"
echo ""
echo "Run 'pnpm test' to execute the smoke tests."
echo "Run 'pnpm infra:down' when you are done to destroy the instance."
