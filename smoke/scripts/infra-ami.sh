#!/usr/bin/env bash
# infra-ami.sh — launch EC2 instance from a novnc-desktop AMI using Terraform
#
# Usage:
#   pnpm infra:ami [OPTIONS] [AMI_ID]
#
# Options:
#   --variant <openbox|elementary>   Desktop variant to find (default: openbox)
#   --http-port <port>               HTTP port (default: 80)
#   --https-port <port>              HTTPS port (default: 443)
#   --domain <zone>                  Parent Route53 zone (e.g. smoke.markcallen.dev)
#   --certbot-email <email>          Email used for certbot registration/renewal
#   --iam-instance-profile <name>    IAM instance profile name for EC2
#   --use-certbot                    Force certbot on first boot (requires domain)
#   --no-certbot                     Force certbot off on first boot
#   --public                         Search for public (production) AMIs instead of test AMIs
#
# If AMI_ID is provided, --variant and --public are ignored for the lookup
# but ports are still applied.
#
# Examples:
#   pnpm infra:ami
#   pnpm infra:ami --variant elementary
#   pnpm infra:ami --domain smoke.markcallen.dev --public
#   pnpm infra:ami --domain smoke.markcallen.dev --certbot-email admin@example.com --public
#   pnpm infra:ami --domain smoke.markcallen.dev --iam-instance-profile novnc-desktop-certbot --public
#   pnpm infra:ami --variant elementary --http-port 8080 --https-port 8443 --public
#   pnpm infra:ami ami-0613b782c7ff5544d
#
# Optional environment variables:
#   VNC_USER   SSH username on the EC2 instance (default: ubuntu)
#   NOVNC_HOSTNAME      Optional explicit hostname passed in EC2 user-data JSON.
#   TLS_ZONE            Optional Route53 zone used to generate unique hostname.
#   LETSENCRYPT_EMAIL Optional certbot email passed in EC2 user-data JSON.
#   NOVNC_USE_CERTBOT   true|false to trigger novnc-setup-tls on first boot.

set -euo pipefail

# Compute REPO_ROOT early so .env can be loaded before defaults are applied.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Load .env from the repo root if present (never required; overrides defaults).
if [[ -f "$REPO_ROOT/.env" ]]; then
  # shellcheck source=/dev/null
  set -a; source "$REPO_ROOT/.env"; set +a
fi

VNC_USER="${VNC_USER:-ubuntu}"
NOVNC_HOSTNAME="${NOVNC_HOSTNAME:-}"
TLS_ZONE="${TLS_ZONE:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
NOVNC_USE_CERTBOT="${NOVNC_USE_CERTBOT:-}"
IAM_INSTANCE_PROFILE="${IAM_INSTANCE_PROFILE:-}"
VARIANT="openbox"
HTTP_PORT=80
HTTPS_PORT=443
ENVIRONMENT="test"
AMI_ID=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      VARIANT="$2"
      shift 2
      ;;
    --http-port)
      HTTP_PORT="$2"
      shift 2
      ;;
    --https-port)
      HTTPS_PORT="$2"
      shift 2
      ;;
    --domain)
      TLS_ZONE="$2"
      shift 2
      ;;
    --certbot-email)
      LETSENCRYPT_EMAIL="$2"
      shift 2
      ;;
    --iam-instance-profile)
      IAM_INSTANCE_PROFILE="$2"
      shift 2
      ;;
    --use-certbot)
      NOVNC_USE_CERTBOT="true"
      shift
      ;;
    --no-certbot)
      NOVNC_USE_CERTBOT="false"
      shift
      ;;
    --public)
      ENVIRONMENT="production"
      shift
      ;;
    --*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      AMI_ID="$1"
      shift
      ;;
  esac
done

if [[ "$VARIANT" != "openbox" && "$VARIANT" != "elementary" ]]; then
  echo "ERROR: --variant must be 'openbox' or 'elementary'" >&2
  exit 1
fi

# If a domain was supplied, default to certbot-enabled unless explicitly
# overridden by --no-certbot or NOVNC_USE_CERTBOT=false.
# With a TLS zone, default to certbot=true unless explicitly overridden.
if [[ -n "$TLS_ZONE" && -z "$NOVNC_USE_CERTBOT" ]]; then
  NOVNC_USE_CERTBOT="true"
fi

if [[ "$NOVNC_USE_CERTBOT" == "true" && -z "$TLS_ZONE" && -z "$NOVNC_HOSTNAME" ]]; then
  echo "ERROR: certbot requires a domain. Set --domain <zone> or NOVNC_HOSTNAME." >&2
  exit 1
fi

if [[ -z "$NOVNC_USE_CERTBOT" ]]; then
  NOVNC_USE_CERTBOT="false"
fi

if [[ "$NOVNC_USE_CERTBOT" == "true" && -z "$IAM_INSTANCE_PROFILE" ]]; then
  IAM_INSTANCE_PROFILE="novnc-desktop-certbot"
fi

if [[ "$NOVNC_USE_CERTBOT" == "true" && -z "$LETSENCRYPT_EMAIL" ]]; then
  echo "ERROR: certbot is enabled but no email was provided." >&2
  echo "Set --certbot-email <valid-email> (or LETSENCRYPT_EMAIL)." >&2
  exit 1
fi

LABEL="infra:ami"

TF_DIR="$REPO_ROOT/smoke/ec2"
KEYS_DIR="$REPO_ROOT/.smoke-keys"
STATE_DIR="$REPO_ROOT/.smoke-state"
ARTIFACTS_DIR="$REPO_ROOT/.smoke-artifacts"
STATE_FILE="$STATE_DIR/state.json"
SSH_KEY_PATH="$KEYS_DIR/smoke.pem"

mkdir -p "$KEYS_DIR" "$STATE_DIR" "$ARTIFACTS_DIR"

if [[ ! -f "$TF_DIR/terraform.tfvars" ]]; then
  echo "ERROR: $TF_DIR/terraform.tfvars not found." >&2
  echo "Copy terraform.tfvars.example to terraform.tfvars and configure it." >&2
  exit 1
fi

AWS_REGION=$(grep 'aws_region' "$TF_DIR/terraform.tfvars" | grep -o '"[^"]*"' | head -1 | tr -d '"')
if [[ -z "$AWS_REGION" ]]; then
  echo "ERROR: Could not read aws_region from terraform.tfvars" >&2
  exit 1
fi

if [[ -z "$AMI_ID" ]]; then
  echo "[$LABEL] Finding most recent $VARIANT AMI (Environment=$ENVIRONMENT) in $AWS_REGION..."
  AMI_ID=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners self \
    --filters "Name=tag:Environment,Values=$ENVIRONMENT" \
              "Name=tag:Variant,Values=$VARIANT" \
              "Name=tag:Project,Values=novnc-desktop" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

  if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    echo "ERROR: No $VARIANT AMI found with Environment=$ENVIRONMENT, Project=novnc-desktop" >&2
    if [[ "$ENVIRONMENT" == "production" ]]; then
      echo "Build one with: NOVNC_HTTP_PORT=$HTTP_PORT NOVNC_HTTPS_PORT=$HTTPS_PORT AMI_PUBLIC=true AMI_ENVIRONMENT=production ./scripts/build-ami.sh" >&2
    else
      echo "Build one with: ./scripts/build-ami.sh" >&2
    fi
    exit 1
  fi
fi

echo "[$LABEL] Using AMI:     $AMI_ID"
echo "[$LABEL] Variant:       $VARIANT"
echo "[$LABEL] HTTP port:     $HTTP_PORT"
echo "[$LABEL] HTTPS port:    $HTTPS_PORT"
echo "[$LABEL] Environment:   $ENVIRONMENT"
echo "[$LABEL] TLS zone:      ${TLS_ZONE:-<none>}"
echo "[$LABEL] Hostname:      ${NOVNC_HOSTNAME:-<auto/imds>}"
echo "[$LABEL] Certbot email: ${LETSENCRYPT_EMAIL:-<default>}"
echo "[$LABEL] Use certbot:   $NOVNC_USE_CERTBOT"
echo "[$LABEL] IAM profile:   ${IAM_INSTANCE_PROFILE:-<none>}"

cd "$TF_DIR"
terraform init -input=false

echo "[$LABEL] Applying Terraform..."
terraform apply -auto-approve -input=false \
  -var "ami_id=$AMI_ID" \
  -var "novnc_http_port=$HTTP_PORT" \
  -var "novnc_https_port=$HTTPS_PORT" \
  -var "novnc_hostname=$NOVNC_HOSTNAME" \
  -var "tls_zone=$TLS_ZONE" \
  -var "novnc_certbot_email=$LETSENCRYPT_EMAIL" \
  -var "novnc_use_certbot=$NOVNC_USE_CERTBOT" \
  -var "iam_instance_profile=$IAM_INSTANCE_PROFILE"

PUBLIC_IP=$(terraform output -raw public_ip)
PUBLIC_DNS=$(terraform output -raw public_dns)
TLS_HOSTNAME=$(terraform output -raw tls_hostname || true)
if [[ -z "$TLS_HOSTNAME" ]]; then
  TLS_HOSTNAME="$NOVNC_HOSTNAME"
fi
echo "[$LABEL] Instance ready: $PUBLIC_IP ($PUBLIC_DNS)"
if [[ -n "$TLS_HOSTNAME" ]]; then
  echo "[$LABEL] TLS hostname:  $TLS_HOSTNAME"
fi
echo "[$LABEL] SSH key written to $SSH_KEY_PATH"

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

# Wait for first-boot userdata configuration to settle. Certbot DNS-01 can
# keep this service in "activating" for a while.
echo "[$LABEL] Waiting for first-boot userdata configuration to settle..."
for attempt in $(seq 1 60); do
  USERDATA_STATE=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY_PATH" "$VNC_USER@$PUBLIC_IP" \
    "systemctl is-active novnc-configure-userdata.service 2>/dev/null || true" 2>/dev/null | tr -d '\r')
  if [[ "$USERDATA_STATE" == "activating" ]]; then
    echo "[$LABEL]   novnc-configure-userdata is still activating (attempt $attempt/60)..."
    sleep 5
    continue
  fi
  echo "[$LABEL]   novnc-configure-userdata state: ${USERDATA_STATE:-unknown}"
  break
done

# ---------------------------------------------------------------------------
# AMI content verification (AC-AMI-02, AC-AMI-03, AC-AMI-04)
# Confirm required commands and services are baked into the AMI before any
# Ansible post-launch run. Failures here indicate a broken AMI build.
# ---------------------------------------------------------------------------
echo ""
echo "[$LABEL] Verifying AMI contents (pre-Ansible)..."

SSH_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY_PATH")
AMI_VERIFY_PASS=true
VERIFY_FAILURE_REASON=""

for cmd in novnc-desktop-url novnc-set-base-url novnc-configure-userdata novnc-setup-tls; do
  ac="AC-AMI-02/03/05"
  if ssh "${SSH_OPTS[@]}" "$VNC_USER@$PUBLIC_IP" "test -x /usr/local/bin/$cmd" 2>/dev/null; then
    echo "[$LABEL]   [PASS] /usr/local/bin/$cmd present ($ac)"
  else
    echo "[$LABEL]   [FAIL] /usr/local/bin/$cmd missing — AMI was not built with all roles" >&2
    AMI_VERIFY_PASS=false
  fi
done

for svc in novnc-auth.service nginx novnc.service novnc-desktop.service novnc-set-base-url.service; do
  ac="AC-AMI-04/06"
  if ssh "${SSH_OPTS[@]}" "$VNC_USER@$PUBLIC_IP" "systemctl is-active --quiet $svc" 2>/dev/null; then
    echo "[$LABEL]   [PASS] $svc active ($ac)"
  else
    echo "[$LABEL]   [FAIL] $svc not active — AMI services did not start on boot" >&2
    AMI_VERIFY_PASS=false
  fi
done

if [[ "$AMI_VERIFY_PASS" == "false" ]]; then
  echo ""
  VERIFY_FAILURE_REASON="AMI content verification failed"
  echo "[$LABEL] WARNING: AMI content verification failed; continuing so state is still written." >&2
else
  echo "[$LABEL] AMI content verification passed."
fi

# ---------------------------------------------------------------------------
# Fetch a time-limited desktop access URL and write it into state
# ---------------------------------------------------------------------------
echo ""
echo "[$LABEL] Fetching desktop access URL..."
DESKTOP_URL_OUTPUT=$(ssh "${SSH_OPTS[@]}" "$VNC_USER@$PUBLIC_IP" novnc-desktop-url 2>&1 || true)
ACCESS_URL=$(echo "$DESKTOP_URL_OUTPUT" | awk '/Desktop URL/{print $NF}' || true)

if [[ -z "$ACCESS_URL" ]]; then
  echo "[$LABEL] WARNING: Could not parse access URL from novnc-desktop-url output:" >&2
  echo "$DESKTOP_URL_OUTPUT" >&2
fi

cat > "$STATE_FILE" <<EOF
{
  "publicIp": "$PUBLIC_IP",
  "publicDns": "$PUBLIC_DNS",
  "vncUser": "$VNC_USER",
  "sshKeyPath": "$SSH_KEY_PATH",
  "amiId": "$AMI_ID",
  "variant": "$VARIANT",
  "novncHttpPort": $HTTP_PORT,
  "novncHttpsPort": $HTTPS_PORT,
  "tlsDomain": "$TLS_HOSTNAME",
  "certbotEmail": "$LETSENCRYPT_EMAIL",
  "verificationPassed": $AMI_VERIFY_PASS,
  "verificationFailureReason": "${VERIFY_FAILURE_REASON}",
  "accessUrl": "$ACCESS_URL"
}
EOF

echo "[$LABEL] State updated with accessUrl."
echo ""
if [[ -n "$ACCESS_URL" ]]; then
  echo "Desktop: $ACCESS_URL"
else
  echo "Desktop URL unavailable; connect via SSH:"
  echo "  ssh -i $SSH_KEY_PATH $VNC_USER@$PUBLIC_IP"
fi
echo ""
echo "Next: run the smoke tests:"
echo "  pnpm test"
echo ""
echo "When done, clean up with:"
echo "  pnpm infra:down"

if [[ "$AMI_VERIFY_PASS" == "false" ]]; then
  echo ""
  echo "[$LABEL] ERROR: AMI runtime verification failed on this instance." >&2
  echo "[$LABEL] Inspect service failures before deciding to rebuild the AMI:" >&2
  echo "  ssh -i $SSH_KEY_PATH $VNC_USER@$PUBLIC_IP" >&2
  echo "  sudo systemctl --failed" >&2
  echo "  sudo journalctl -u novnc-configure-userdata -n 200 --no-pager" >&2
  echo "  sudo journalctl -u novnc-auth -n 200 --no-pager" >&2
  exit 1
fi
