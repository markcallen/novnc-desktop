# User Metadata Script Examples

This directory contains example user-data scripts for launching novnc-desktop AMIs
with automatic TLS certificate configuration.

## Overview

AMIs built with `use_certbot: false` (the default for public AMIs) ship with a
self-signed certificate. The AMI includes `/usr/local/bin/novnc-setup-tls`, which
handles the complete TLS setup at launch time:

1. Obtains a certificate from Let's Encrypt via the certbot nginx plugin.
2. Patches the nginx site config to serve the real certificate.
3. Updates the auth service `base_url` so `novnc-desktop-url` generates correct links.
4. Installs an automatic renewal hook.

## certbot Example

**File**: `user-metadata-certbot-example.sh`

### Prerequisites

- A domain name you control (e.g. `myapp.example.com`).
- DNS `A` record pointing to the instance's public IP **before** launch.
- Security group with inbound TCP on port 80 and your HTTPS port (default 443).

### Usage

#### Option 1: EC2 Console

1. Launch an EC2 instance from an openbox or elementary AMI.
2. Under **Advanced Details → User data**, paste:

```bash
#!/bin/bash
export CERTBOT_DOMAIN=myapp.example.com
export CERTBOT_EMAIL=admin@example.com
export NOVNC_HTTPS_PORT=443

# Paste the contents of user-metadata-certbot-example.sh here
```

#### Option 2: AWS CLI

Create a combined user-data file:

```bash
cat > user-data.sh <<'EOF'
#!/bin/bash
export CERTBOT_DOMAIN=myapp.example.com
export CERTBOT_EMAIL=admin@example.com
export NOVNC_HTTPS_PORT=443
EOF
cat examples/user-metadata-certbot-example.sh >> user-data.sh
```

Then launch the instance (see `docs/launch-from-ami.md` for the full AWS CLI workflow):

```bash
aws ec2 run-instances \
  --image-id ami-XXXXXXXX \
  --instance-type t3.medium \
  --user-data file://user-data.sh \
  --security-group-ids sg-XXXXXXXX \
  --key-name my-keypair
```

#### Option 3: Terraform

Because `/usr/local/bin/novnc-setup-tls` is baked into the AMI, the user-data
only needs to export variables and call the script — no file embedding required.

```hcl
resource "aws_instance" "novnc_with_tls" {
  ami           = var.novnc_ami_id
  instance_type = "t3.medium"
  key_name      = aws_key_pair.main.key_name

  vpc_security_group_ids = [aws_security_group.novnc.id]

  user_data = <<-USERDATA
    #!/bin/bash
    export CERTBOT_DOMAIN=${var.certbot_domain}
    export CERTBOT_EMAIL=${var.certbot_email}
    export NOVNC_HTTPS_PORT=${var.novnc_https_port}
    /usr/local/bin/novnc-setup-tls
  USERDATA

  tags = {
    Name = "novnc-with-tls"
  }
}
```

### Environment Variables

| Variable          | Default              | Description                                                     |
| ----------------- | -------------------- | --------------------------------------------------------------- |
| `CERTBOT_DOMAIN`  | (required)           | Domain for the certificate (e.g. `myapp.example.com`)           |
| `CERTBOT_EMAIL`   | `admin@example.com`  | Email for Let's Encrypt expiry notices                          |
| `NOVNC_HTTPS_PORT`| `443`                | HTTPS port nginx listens on (must match AMI provisioning value) |
| `NOVNC_SERVICE`   | `novnc-desktop`      | systemd service name                                            |

### What Happens

1. **User-data runs** as root during instance initialization.
2. **`/usr/local/bin/novnc-setup-tls` is called**, which:
   - Runs `certbot --nginx` to obtain a certificate and patch the nginx config.
   - Updates `/etc/novnc-auth/config.json` with the correct `base_url`.
   - Installs a renewal post-hook at `/etc/letsencrypt/renewal-hooks/post/novnc-renew.sh`.
3. **novnc-auth restarts** to reload its config.
4. The full stack (TigerVNC, noVNC, novnc-auth, nginx) remains running throughout,
   managed by the `novnc-desktop` meta-service.

### Verification

After the instance is fully initialized (typically 2–4 minutes):

```bash
# SSH into the instance
ssh -i my-keypair.pem ubuntu@<instance-ip>

# Check the full stack status
sudo systemctl status novnc-desktop

# View TLS setup logs
sudo tail -f /var/log/novnc-setup-tls.log

# Verify the certificate
sudo certbot certificates

# Get your signed access URL
sudo novnc-desktop-url
```

### Troubleshooting

#### Certificate acquisition failed

**Cause**: Port 80 not reachable, or DNS not propagated to this instance's IP.

**Solution**:
- Check security group allows inbound TCP on port 80 from `0.0.0.0/0`.
- Verify `dig +short myapp.example.com` returns this instance's public IP.
- Re-run manually: `sudo CERTBOT_DOMAIN=myapp.example.com /usr/local/bin/novnc-setup-tls`

#### novnc-desktop service is not active

```bash
sudo systemctl status novnc-desktop
sudo journalctl -u novnc-desktop -n 50

# Individual service logs
sudo journalctl -u nginx -n 30
sudo journalctl -u novnc-auth -n 30
```

#### Certificate renewal fails

```bash
# Dry run to test renewal
sudo certbot renew --dry-run

# Force renewal
sudo certbot renew --force-renewal
```

### Advanced: DNS-01 Validation via Route53

For domains hosted in Route53 (avoids the port 80 requirement):

```bash
apt-get install -y python3-certbot-dns-route53

certbot certonly \
  --dns-route53 \
  --non-interactive \
  --agree-tos \
  --email "$CERTBOT_EMAIL" \
  -d "$CERTBOT_DOMAIN"
```

Requires the instance to have an IAM role with Route53 permissions:
`route53:ListHostedZones`, `route53:GetChange`, `route53:ChangeResourceRecordSets`.

### Security Considerations

1. Restrict inbound port 80 to `0.0.0.0/0` only during initial validation; tighten afterwards.
2. Keep `/etc/letsencrypt/` private — never expose private keys.
3. Use a monitored email address for Let's Encrypt expiry notifications.
4. Restrict SSH access (`port 22`) to known IP ranges in the security group.
