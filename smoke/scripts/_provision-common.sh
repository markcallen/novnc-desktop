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
#   NOVNC_HTTP_PORT  — public HTTP port passed to the role (default: 80)
#   NOVNC_HTTPS_PORT — public HTTPS port passed to the role (default: 443)
#
# When state.json contains tlsDomain (written by infra-up-tls.sh), Ansible is
# invoked with use_certbot=true and letsencrypt_email so certbot obtains a
# Let's Encrypt certificate automatically during provisioning.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_DIR="$REPO_ROOT/.smoke-state"
STATE_FILE="$STATE_DIR/state.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: No infrastructure state found at $STATE_FILE." >&2
  echo "Run 'pnpm infra:up' first to provision the EC2 instance." >&2
  exit 1
fi

# Load credentials and AMI/TLS metadata from state file; allow environment variable overrides.
_STATE_VNC_USER=$(jq -r '.vncUser // "ubuntu"' "$STATE_FILE")
_STATE_SSH_KEY_PATH=$(jq -r '.sshKeyPath // ""' "$STATE_FILE")
_STATE_AMI_ID=$(jq -r '.amiId // ""' "$STATE_FILE")
_STATE_VARIANT=$(jq -r '.variant // ""' "$STATE_FILE")
_STATE_TLS_DOMAIN=$(jq -r '.tlsDomain // ""' "$STATE_FILE")
_STATE_TLS_ZONE=$(jq -r '.tlsZone // ""' "$STATE_FILE")

VNC_USER="${VNC_USER:-$_STATE_VNC_USER}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${_STATE_SSH_KEY_PATH:-$REPO_ROOT/.smoke-keys/smoke.pem}}"
NOVNC_HTTP_PORT="${NOVNC_HTTP_PORT:-80}"
NOVNC_HTTPS_PORT="${NOVNC_HTTPS_PORT:-443}"

PUBLIC_IP=$(jq -r '.publicIp' "$STATE_FILE")
PUBLIC_DNS=$(jq -r '.publicDns' "$STATE_FILE")

validate_port() {
  local value="$1"
  local name="$2"

  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    echo "ERROR: $name must be an integer TCP port between 1 and 65535. Received: $value" >&2
    exit 1
  fi
}

validate_port "$NOVNC_HTTP_PORT" "NOVNC_HTTP_PORT"
validate_port "$NOVNC_HTTPS_PORT" "NOVNC_HTTPS_PORT"

# ---------------------------------------------------------------------------
# 1. Ansible Galaxy dependencies
# ---------------------------------------------------------------------------
echo "[provision:$DESKTOP_TYPE] Installing Ansible Galaxy requirements..."
cd "$REPO_ROOT"
ansible-galaxy install -r requirements.yml --force

# ---------------------------------------------------------------------------
# 1b. Terraform — align smoke security group ingress with the requested ports
# ---------------------------------------------------------------------------
echo "[provision:$DESKTOP_TYPE] Ensuring smoke security group allows HTTP $NOVNC_HTTP_PORT and HTTPS $NOVNC_HTTPS_PORT..."
cd "$REPO_ROOT/smoke/ec2"
_TF_TLS_ZONE_VAR=()
if [[ -n "$_STATE_TLS_ZONE" ]]; then
  _TF_TLS_ZONE_VAR=(-var "tls_zone=$_STATE_TLS_ZONE")
fi
terraform apply \
  -auto-approve \
  -input=false \
  -var "novnc_http_port=$NOVNC_HTTP_PORT" \
  -var "novnc_https_port=$NOVNC_HTTPS_PORT" \
  "${_TF_TLS_ZONE_VAR[@]}"

PUBLIC_IP=$(terraform output -raw public_ip)
PUBLIC_DNS=$(terraform output -raw public_dns)
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 2. Ansible — provision the desktop
# smoke_test_marker_enabled=true renders the bright-green xterm that the
# Playwright desktop test looks for on the canvas.
# When tlsDomain is set (written by infra:up:tls), certbot is enabled and
# the Let's Encrypt certificate is obtained during provisioning.
# ---------------------------------------------------------------------------
_ANSIBLE_TLS_VARS=""
if [[ -n "$_STATE_TLS_DOMAIN" ]]; then
  _ANSIBLE_TLS_VARS=" use_certbot=true tls_domain=$_STATE_TLS_DOMAIN letsencrypt_email=mark@markcallen.dev"
  echo "[provision:$DESKTOP_TYPE] TLS domain detected: $_STATE_TLS_DOMAIN (certbot enabled)"
fi

echo "[provision:$DESKTOP_TYPE] Provisioning with Ansible (this takes ~5-10 min)..."
# shellcheck disable=SC2086
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook site.yml \
  -i "$PUBLIC_IP," \
  -u "$VNC_USER" \
  --private-key "$SSH_KEY_PATH" \
  -e "public_ip=$PUBLIC_IP desktop_type=$DESKTOP_TYPE smoke_test_marker_enabled=true novnc_http_port=$NOVNC_HTTP_PORT novnc_https_port=$NOVNC_HTTPS_PORT$_ANSIBLE_TLS_VARS"

# ---------------------------------------------------------------------------
# 2b. Update novnc-auth config with the canonical base URL.
# When a TLS domain is configured use it; otherwise fall back to public IP.
# ---------------------------------------------------------------------------
if [[ -n "$_STATE_TLS_DOMAIN" ]]; then
  _BASE_URL="https://$_STATE_TLS_DOMAIN"
else
  _BASE_URL="https://$PUBLIC_IP"
fi
echo "[provision:$DESKTOP_TYPE] Updating novnc-auth base URL to $_BASE_URL..."
CFG="/etc/novnc-auth/config.json"
PY_CMD="import json; c=json.load(open('${CFG}')); c['base_url']='${_BASE_URL}'; f=open('${CFG}','w'); json.dump(c,f,indent=2); f.write('\n'); f.close()"
# shellcheck disable=SC2029
ssh \
  -o StrictHostKeyChecking=no \
  -i "$SSH_KEY_PATH" \
  "$VNC_USER@$PUBLIC_IP" \
  "sudo python3 -c \"${PY_CMD}\" && sudo systemctl restart novnc-auth.service" && \
  echo "[provision:$DESKTOP_TYPE] Base URL set to $_BASE_URL" || \
  echo "[provision:$DESKTOP_TYPE] Warning: Could not update base URL; novnc-desktop-url may show incorrect URL"

# ---------------------------------------------------------------------------
# 3. Fetch a time-limited desktop access URL
# ---------------------------------------------------------------------------
echo "[provision:$DESKTOP_TYPE] Fetching desktop access URL..."
DESKTOP_URL_OUTPUT=$(
  ssh \
    -o StrictHostKeyChecking=no \
    -i "$SSH_KEY_PATH" \
    "$VNC_USER@$PUBLIC_IP" \
    novnc-desktop-url
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
_TLS_DOMAIN_JSON=""
if [[ -n "$_STATE_TLS_DOMAIN" ]]; then
  _TLS_DOMAIN_JSON="
  \"tlsDomain\": \"$_STATE_TLS_DOMAIN\","
fi

cat > "$STATE_FILE" <<EOF
{
  "publicIp": "$PUBLIC_IP",
  "publicDns": "$PUBLIC_DNS",
  "accessUrl": "$ACCESS_URL",
  "desktopType": "$DESKTOP_TYPE",
  "novncHttpPort": $NOVNC_HTTP_PORT,
  "novncHttpsPort": $NOVNC_HTTPS_PORT,
  "vncUser": "$VNC_USER",
  "sshKeyPath": "$SSH_KEY_PATH",
  "amiId": "$_STATE_AMI_ID",
  "variant": "$_STATE_VARIANT"${_TLS_DOMAIN_JSON}
}
EOF

echo ""
echo "[provision:$DESKTOP_TYPE] State saved to $STATE_FILE"
echo ""
echo "  Desktop URL : $ACCESS_URL"
echo "  SSH         : ssh -i $SSH_KEY_PATH $VNC_USER@$PUBLIC_IP"
echo ""
echo "Run 'pnpm test' to execute the smoke tests."
echo "Run 'pnpm infra:down' when you are done to destroy the instance."
