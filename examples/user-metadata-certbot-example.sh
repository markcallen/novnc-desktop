#!/bin/bash
# Example user metadata script for EC2 instances launched from novnc-desktop AMIs
# with use_certbot: false
#
# This script:
# 1. Installs certbot and obtains a real TLS certificate from Let's Encrypt
# 2. Configures custom ports for novnc-server
# 3. Restarts the service with the new configuration
#
# Usage:
# Create a user-data script by prepending your environment variables and
# appending this file's contents. Do NOT use command substitution inside a
# quoted heredoc — the file will not be present on the EC2 instance.
#
#   cat > user-data.sh <<EOF
#   #!/bin/bash
#   export CERTBOT_DOMAIN=myapp.example.com
#   export CERTBOT_EMAIL=admin@example.com
#   export NOVNC_PORT=443
#   export NOVNC_UNSECURED_PORT=80
#   EOF
#   cat examples/user-metadata-certbot-example.sh >> user-data.sh
#
# Then launch:
#   aws ec2 run-instances \
#     --image-id ami-xxxxx \
#     --user-data file://user-data.sh
#
# Or via EC2 console, paste the env-var block followed by this script's
# contents directly into the User data field.

set -euo pipefail

# Configuration from environment variables (with defaults)
CERTBOT_DOMAIN="${CERTBOT_DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-certbot@example.com}"
NOVNC_PORT="${NOVNC_PORT:-443}"
NOVNC_UNSECURED_PORT="${NOVNC_UNSECURED_PORT:-80}"
NOVNC_CONFIG_DIR="${NOVNC_CONFIG_DIR:-/home/novnc}"
NOVNC_SERVICE_NAME="${NOVNC_SERVICE_NAME:-novnc-desktop}"

# Logging
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/novnc-setup.log
}

error() {
  echo "[ERROR] $*" | tee -a /var/log/novnc-setup.log
  exit 1
}

# Validate required configuration
if [ -z "$CERTBOT_DOMAIN" ]; then
  error "CERTBOT_DOMAIN environment variable is required. Set it to your domain name (e.g., myapp.example.com)"
fi

log "Starting novnc-server TLS configuration"
log "Domain: $CERTBOT_DOMAIN"
log "HTTPS Port: $NOVNC_PORT"
log "HTTP Port (fallback): $NOVNC_UNSECURED_PORT"

# Step 1: Stop novnc-desktop stack so port 80 is free for certbot standalone mode
log "Stopping $NOVNC_SERVICE_NAME to release port 80 for certbot..."
systemctl stop "$NOVNC_SERVICE_NAME" || true

# Ensure the stack is always restarted even if a later step fails
trap 'log "Restoring $NOVNC_SERVICE_NAME after exit..."; systemctl start "$NOVNC_SERVICE_NAME" || true' EXIT

# Step 2: Install certbot and certbot DNS plugin(s) if needed
log "Installing certbot..."
apt-get update -qq
apt-get install -y -qq certbot certbot-nginx || apt-get install -y -qq certbot
log "certbot installed successfully"

# Step 3: Obtain certificate from Let's Encrypt
# This uses the standalone mode; adjust to dns-01 or webroot if needed
log "Obtaining TLS certificate for $CERTBOT_DOMAIN..."

certbot certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --email "$CERTBOT_EMAIL" \
  --cert-name "$CERTBOT_DOMAIN" \
  -d "$CERTBOT_DOMAIN" 2>&1 | tee -a /var/log/novnc-setup.log || {
  # If standalone fails (e.g., port 80 in use), try webroot or skip
  log "Standalone certbot failed. Attempting webroot mode or manual setup..."
  # You can add fallback logic here, e.g., webroot with a temporary directory
  # For now, we'll exit with a clear error
  error "Certificate acquisition failed. Ensure port 80 is available or use DNS-01 validation."
}

# Step 4: Verify certificate location
CERT_PATH="/etc/letsencrypt/live/$CERTBOT_DOMAIN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$CERTBOT_DOMAIN/privkey.pem"

if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
  error "Certificate files not found at expected paths: $CERT_PATH, $KEY_PATH"
fi

log "Certificate obtained: $CERT_PATH"

# Step 5: Update novnc-server configuration
# This assumes novnc-server is managed via a systemd service
# Adjust paths and service names based on your AMI configuration

log "Updating novnc-server configuration..."

# Create or update the novnc environment file
NOVNC_ENV_FILE="/etc/novnc/novnc.env"
mkdir -p "$(dirname "$NOVNC_ENV_FILE")"

cat > "$NOVNC_ENV_FILE" << EOF
# novnc-server configuration
NOVNC_PORT=$NOVNC_PORT
NOVNC_UNSECURED_PORT=$NOVNC_UNSECURED_PORT
NOVNC_CERT_PATH=$CERT_PATH
NOVNC_KEY_PATH=$KEY_PATH
CERTBOT_DOMAIN=$CERTBOT_DOMAIN
EOF

log "Configuration written to $NOVNC_ENV_FILE"

# Step 6: Create or update systemd drop-in to use the certificate
# This example assumes novnc-server is a systemd service
# Adjust the service name and configuration based on your setup

SYSTEMD_DROPINS_DIR="/etc/systemd/system/${NOVNC_SERVICE_NAME}.service.d"
mkdir -p "$SYSTEMD_DROPINS_DIR"

cat > "$SYSTEMD_DROPINS_DIR/tls-config.conf" << EOF
[Service]
Environment="NOVNC_PORT=$NOVNC_PORT"
Environment="NOVNC_UNSECURED_PORT=$NOVNC_UNSECURED_PORT"
Environment="NOVNC_CERT_PATH=$CERT_PATH"
Environment="NOVNC_KEY_PATH=$KEY_PATH"
EOF

log "Systemd configuration updated"

# Step 7: Restart novnc-desktop stack with new certificate configuration
log "Restarting $NOVNC_SERVICE_NAME..."

systemctl daemon-reload
systemctl start "$NOVNC_SERVICE_NAME" || error "Failed to start $NOVNC_SERVICE_NAME"

# Verify service is running
sleep 2
if systemctl is-active --quiet "$NOVNC_SERVICE_NAME"; then
  log "$NOVNC_SERVICE_NAME is running with TLS enabled"
else
  error "$NOVNC_SERVICE_NAME failed to start. Check logs: systemctl status $NOVNC_SERVICE_NAME"
fi

# Step 8: Set up automatic certificate renewal via certbot cron
log "Setting up automatic certificate renewal..."

# Create a renewal hook to restart novnc-server when the certificate is renewed
RENEWAL_HOOK_DIR="/etc/letsencrypt/renewal-hooks/post"
mkdir -p "$RENEWAL_HOOK_DIR"

cat > "$RENEWAL_HOOK_DIR/novnc-restart.sh" << HOOK_EOF
#!/bin/bash
# Restart novnc-desktop meta-service after certificate renewal
systemctl restart ${NOVNC_SERVICE_NAME} || logger -t novnc-certbot "Failed to restart ${NOVNC_SERVICE_NAME} after cert renewal"
HOOK_EOF

chmod +x "$RENEWAL_HOOK_DIR/novnc-restart.sh"

log "Certificate renewal hook installed"

# Step 9: Summary
log "=========================================="
log "novnc-server TLS configuration complete!"
log "=========================================="
log "Domain: $CERTBOT_DOMAIN"
log "HTTPS Port: $NOVNC_PORT"
log "HTTP Port: $NOVNC_UNSECURED_PORT"
log "Certificate: $CERT_PATH"
log "Certificate Renewal: Automatic via certbot (renewal hook configured)"
log ""
log "Access your novnc server at:"
log "  https://$CERTBOT_DOMAIN:$NOVNC_PORT"
log ""
log "To manually renew certificates:"
log "  sudo certbot renew"
log ""
log "Service logs:"
log "  sudo journalctl -u $NOVNC_SERVICE_NAME -f"
log "Setup logs:"
log "  tail -f /var/log/novnc-setup.log"
log "=========================================="
