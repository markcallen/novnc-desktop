# User Metadata Script Examples

This directory contains example user metadata scripts for launching novnc-desktop AMIs with custom TLS certificate configurations.

## Overview

When an AMI is built with `use_certbox: false`, it launches without an embedded self-signed certificate. This allows you to provide your own TLS certificates at instance launch time via user metadata scripts.

## certbot Example

**File**: `user-metadata-certbot-example.sh`

This script demonstrates how to:
1. Install certbot
2. Obtain a real TLS certificate from Let's Encrypt
3. Configure novnc-server to use the certificate on custom ports
4. Set up automatic certificate renewal

### Prerequisites

- A domain name you control (e.g., `myapp.example.com`)
- DNS pointing to your EC2 instance
- Port 80 accessible from the internet (for standalone certbot validation)

### Usage

#### Option 1: EC2 Console

1. Launch an EC2 instance from the openbox or elementary AMI
2. Under "Advanced Details" → "User Data", paste the script with environment variables set:

```bash
#!/bin/bash
export CERTBOT_DOMAIN=myapp.example.com
export CERTBOT_EMAIL=admin@example.com
export NOVNC_PORT=443
export NOVNC_UNSECURED_PORT=80

# Paste the contents of user-metadata-certbot-example.sh here
```

#### Option 2: AWS CLI

```bash
aws ec2 run-instances \
  --image-id ami-xxxxx \
  --instance-type t3.medium \
  --key-name my-keypair \
  --security-groups novnc-sg \
  --user-data file://user-metadata-certbot-example.sh \
  --metadata-options "HttpTokens=required" \
  --environment '{
    "CERTBOT_DOMAIN": "myapp.example.com",
    "CERTBOT_EMAIL": "admin@example.com",
    "NOVNC_PORT": "443",
    "NOVNC_UNSECURED_PORT": "80"
  }'
```

#### Option 3: Custom Terraform Module

```hcl
resource "aws_instance" "novnc_with_tls" {
  ami                    = var.novnc_ami_id
  instance_type          = "t3.medium"
  key_name               = aws_key_pair.main.key_name
  vpc_security_group_ids = [aws_security_group.novnc.id]

  user_data = base64encode(templatefile("${path.module}/user-metadata-certbot-example.sh", {
    certbot_domain            = var.certbot_domain
    certbot_email             = var.certbot_email
    novnc_port                = var.novnc_port
    novnc_unsecured_port      = var.novnc_unsecured_port
  }))

  tags = {
    Name = "novnc-with-tls"
  }
}
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CERTBOT_DOMAIN` | (required) | Domain for certificate (e.g., `myapp.example.com`) |
| `CERTBOT_EMAIL` | `certbot@example.com` | Email for Let's Encrypt notifications |
| `NOVNC_PORT` | `443` | HTTPS port for novnc-server |
| `NOVNC_UNSECURED_PORT` | `80` | HTTP port (fallback/redirect) |
| `NOVNC_CONFIG_DIR` | `/home/novnc` | novnc-server home directory |
| `NOVNC_SERVICE_NAME` | `novnc-server` | systemd service name |

### What Happens

1. **Script execution**: User data script runs as root during instance initialization
2. **Certbot installation**: Installs certbot and creates certificate via standalone validation
3. **Configuration**: Updates novnc-server environment and systemd drop-in configs
4. **Service restart**: Restarts novnc-server with TLS enabled
5. **Renewal setup**: Configures automatic certificate renewal with post-renewal hooks

### Verification

After the instance is fully initialized (wait ~2–5 minutes), verify the setup:

```bash
# SSH into the instance
ssh -i my-keypair.pem ubuntu@<instance-ip>

# Check novnc-server status
sudo systemctl status novnc-server

# View setup logs
sudo tail -f /var/log/novnc-setup.log

# Verify certificate
sudo certbot certificates

# Test HTTPS access (from local machine, assuming port 443 is open)
curl --insecure https://<instance-ip>:443
```

### Troubleshooting

#### Certificate acquisition failed

**Cause**: Port 80 is not accessible, or DNS isn't configured.

**Solution**:
- Ensure security group allows inbound on port 80
- Verify DNS resolves to the instance IP
- Consider using DNS-01 validation instead of standalone (requires Route53 or other DNS provider)

#### novnc-server fails to restart

**Cause**: Configuration syntax error or cert paths incorrect.

**Solution**:
```bash
# Check service logs
sudo journalctl -u novnc-server -n 50

# Check configuration file
sudo cat /etc/novnc/novnc.env

# Manually restart with debug output
sudo systemctl restart novnc-server -v
```

#### Certificate renewal fails

**Cause**: Port 80 becomes blocked or domain changes.

**Solution**:
```bash
# Manually trigger renewal (happens automatically monthly)
sudo certbot renew --force-renewal

# Check renewal logs
sudo certbot renew --dry-run
```

### Advanced Customization

#### Custom DNS Validation (Route53)

For domains hosted in Route53, modify the certbot call to use DNS-01:

```bash
# Instead of standalone, use DNS plugin
certbot certonly \
  --dns-route53 \
  --non-interactive \
  --agree-tos \
  --email "$CERTBOT_EMAIL" \
  -d "$CERTBOT_DOMAIN"
```

Requires: `pip install certbot-dns-route53` and IAM role with Route53 permissions.

#### Wildcard Certificates

To issue a wildcard certificate:

```bash
certbot certonly \
  --dns-route53 \
  -d "$CERTBOT_DOMAIN" \
  -d "*.$CERTBOT_DOMAIN"
```

#### Custom Certificate Paths

If you have certificates from another provider (e.g., AWS Certificate Manager), mount them via:

```bash
# Symlink external certs
sudo ln -s /path/to/external/cert /etc/letsencrypt/live/custom/fullchain.pem
sudo ln -s /path/to/external/key /etc/letsencrypt/live/custom/privkey.pem
```

Then update `NOVNC_CERT_PATH` and `NOVNC_KEY_PATH` accordingly.

### Security Considerations

1. **Security Group**: Restrict inbound to your IP ranges, not 0.0.0.0/0
2. **Port 80**: Only needed for standalone validation; close it after setup if not needed
3. **Private Keys**: Never expose `/etc/letsencrypt/live/` outside the instance
4. **Email**: Use a monitored email address for Let's Encrypt renewal notifications
5. **Logs**: Remove or redact sensitive information from logs before sharing

### Next Steps

- Deploy the script to your infrastructure (Terraform, CloudFormation, etc.)
- Monitor certificate renewal via Let's Encrypt emails
- Set up CloudWatch alarms for service health
- Consider automated backups of `/etc/letsencrypt/` for disaster recovery
