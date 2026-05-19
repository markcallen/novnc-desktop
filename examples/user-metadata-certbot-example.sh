#!/bin/bash
# Example EC2 user-data script for novnc-desktop AMIs built with use_certbot=false.
#
# The AMI ships /usr/local/bin/novnc-setup-tls which handles the full TLS
# setup: obtains a Let's Encrypt certificate via the certbot nginx plugin,
# patches the nginx config, updates the auth service base URL, and installs
# an automatic renewal hook.
#
# Usage — create a user-data file and prepend your environment variables:
#
#   cat > user-data.sh <<'EOF'
#   #!/bin/bash
#   export CERTBOT_DOMAIN=myapp.example.com
#   export CERTBOT_EMAIL=admin@example.com
#   EOF
#   cat examples/user-metadata-certbot-example.sh >> user-data.sh
#
# Then launch:
#   aws ec2 run-instances \
#     --image-id ami-xxxxx \
#     --user-data file://user-data.sh
#
# Or paste the env-var block and this file's contents directly into the EC2
# console User data field (Advanced Details → User data).
#
# Environment variables (set above this block):
#   CERTBOT_DOMAIN   (required) Public domain name pointing to this instance.
#   CERTBOT_EMAIL    Email for Let's Encrypt expiry notices.
#                    Default: admin@example.com
#   NOVNC_HTTPS_PORT HTTPS port the AMI was provisioned with. Default: 443
#   NOVNC_SERVICE    systemd service name. Default: novnc-desktop

set -euo pipefail

# Configuration — override these by exporting variables before this block.
CERTBOT_DOMAIN="${CERTBOT_DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin@example.com}"
NOVNC_HTTPS_PORT="${NOVNC_HTTPS_PORT:-443}"
NOVNC_SERVICE="${NOVNC_SERVICE:-novnc-desktop}"

if [ -z "$CERTBOT_DOMAIN" ]; then
  echo "ERROR: CERTBOT_DOMAIN is required. Set it before running this script." >&2
  exit 1
fi

export CERTBOT_DOMAIN CERTBOT_EMAIL NOVNC_HTTPS_PORT NOVNC_SERVICE

# Run the TLS setup script that was installed on the AMI by Ansible.
/usr/local/bin/novnc-setup-tls
