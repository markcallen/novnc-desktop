# Running noVNC Desktop on Custom Ports (8080 / 8443)

This guide covers building and launching openbox and elementary AMIs on ports
8080 (HTTP) and 8443 (HTTPS) — with a self-signed certificate or with a
Let's Encrypt certificate via certbot.

## How certbot works on public AMIs

Public AMIs are built with `use_certbot=false` and ship a self-signed
certificate. TLS is configured at launch time by the `novnc-setup-tls` script
using the certbot **dns-route53** plugin (DNS-01 challenge).

DNS-01 proves domain ownership by creating a `_acme-challenge` TXT record in
Route53 — it does not need port 80 open and works regardless of which HTTPS
port the AMI was built with.

**Prerequisites for certbot on any port:**

- The domain's hosted zone must exist in Route53 in the same AWS account.
- The EC2 instance must have an IAM role with Route53 permissions.

See [route53-iam-setup.md](./route53-iam-setup.md) for the full IAM setup.

---

## Scenario A — Self-signed certificate on 8080 / 8443

No domain, DNS, or IAM role required.

### 1. Build the AMI

```bash
NOVNC_HTTP_PORT=8080 NOVNC_HTTPS_PORT=8443 \
  AMI_PUBLIC=true AMI_ENVIRONMENT=production \
  ./build-ami.sh
```

Builds both **openbox** and **elementary** variants.

### 2. Create a security group

```bash
VPC_ID=vpc-XXXXXXXX
MY_IP=$(curl -s https://checkip.amazonaws.com)/32

SG_ID=$(aws ec2 create-security-group \
  --group-name novnc-selfsigned-sg \
  --description "noVNC Desktop self-signed 8080/8443" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP"

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 8080 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 8443 --cidr 0.0.0.0/0
```

### 3. Launch — no user-data needed

```bash
AMI_ID=ami-XXXXXXXX
SUBNET_ID=subnet-XXXXXXXX

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.medium \
  --key-name novnc-desktop-key \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=novnc-desktop}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Desktop: https://$PUBLIC_IP:8443"
```

Accept the self-signed certificate warning in your browser.

---

## Scenario B — Let's Encrypt certificate on 8080 / 8443

DNS-01 means no port-80 requirement — certbot works on any port combination.

### Prerequisites

1. Complete the [Route53 IAM setup](./route53-iam-setup.md) to create the
   `novnc-desktop-certbot` instance profile.
2. Create a DNS `A` record for your domain pointing to the instance's public IP
   before `novnc-setup-tls` runs. Use an Elastic IP (see
   [launch-from-ami.md](./launch-from-ami.md#using-an-elastic-ip-recommended-for-production))
   to know the IP before launch.

### 1. Build the AMI

```bash
NOVNC_HTTP_PORT=8080 NOVNC_HTTPS_PORT=8443 \
  AMI_PUBLIC=true AMI_ENVIRONMENT=production \
  ./build-ami.sh
```

### 2. Create a security group

Port 80 is not needed.

```bash
VPC_ID=vpc-XXXXXXXX
MY_IP=$(curl -s https://checkip.amazonaws.com)/32

SG_ID=$(aws ec2 create-security-group \
  --group-name novnc-dns01-sg \
  --description "noVNC Desktop DNS-01 8080/8443" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP"

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 8443 --cidr 0.0.0.0/0
```

### 3. Prepare the user-data script

```bash
cat > user-data.sh <<'EOF'
#!/bin/bash
export CERTBOT_DOMAIN=myapp.example.com
export CERTBOT_EMAIL=admin@example.com
export NOVNC_HTTPS_PORT=8443
EOF
cat examples/user-metadata-certbot-example.sh >> user-data.sh
```

### 4. Launch with the IAM instance profile

```bash
AMI_ID=ami-XXXXXXXX
SUBNET_ID=subnet-XXXXXXXX

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.medium \
  --key-name novnc-desktop-key \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --iam-instance-profile Name=novnc-desktop-certbot \
  --user-data file://user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=novnc-desktop}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
```

### 5. Monitor and access

```bash
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

ssh -i novnc-desktop-key.pem ubuntu@"$PUBLIC_IP"

sudo tail -f /var/log/novnc-setup-tls.log   # completes in ~2 minutes

sudo novnc-desktop-url
# → https://myapp.example.com:8443/access?token=...
```

### Running TLS setup manually

```bash
sudo CERTBOT_DOMAIN=myapp.example.com \
     CERTBOT_EMAIL=admin@example.com \
     NOVNC_HTTPS_PORT=8443 \
     /usr/local/bin/novnc-setup-tls
```

---

## Choosing between openbox and elementary

Both variants are built from the same Packer run and accept identical launch
parameters.

| Variant    | Desktop                | AMI name suffix               |
| ---------- | ---------------------- | ----------------------------- |
| openbox    | Openbox (lightweight)  | `-openbox-YYYYMMDD-hhmmss`    |
| elementary | Elementary OS Pantheon | `-elementary-YYYYMMDD-hhmmss` |

Find the AMI IDs after a build:

```bash
aws ec2 describe-images \
  --filters \
    "Name=name,Values=novnc-desktop-ubuntu-24.04-*" \
    "Name=tag:Environment,Values=production" \
  --query 'Images[*].[ImageId,Name,CreationDate]' \
  --output table \
  --region us-east-1
```

---

## Variable reference

| `build-ami.sh` env var | Default | Notes                               |
| ---------------------- | ------- | ----------------------------------- |
| `NOVNC_HTTP_PORT`      | `80`    | HTTP redirect port baked into nginx |
| `NOVNC_HTTPS_PORT`     | `443`   | HTTPS desktop port baked into nginx |
| `AMI_PUBLIC`           | `false` | Set `true` for public AMIs          |
| `AMI_ENVIRONMENT`      | `test`  | Use `production` for releases       |

## Troubleshooting

### certbot fails with "unable to determine base domain"

The domain's hosted zone is not in the Route53 account. Check:

```bash
aws route53 list-hosted-zones \
  --query 'HostedZones[*].[Name,Id]' --output table
```

### certbot fails with "Access denied" or credential error

The instance IAM role is missing Route53 permissions or was not attached. Check:

```bash
# From the instance
curl -s http://169.254.169.254/latest/meta-data/iam/info
aws route53 list-hosted-zones   # should succeed if IAM is correct
```

See [route53-iam-setup.md](./route53-iam-setup.md).

### Browser shows "This site can't be reached" on port 8443

- Confirm the security group allows inbound TCP on 8443.
- Confirm the AMI was built with `NOVNC_HTTPS_PORT=8443`.
- Check nginx is running: `sudo systemctl status nginx`.

### Self-signed certificate warning in browser (Scenario A)

Expected. To copy the cert for local trust:

```bash
scp -i novnc-desktop-key.pem \
  ubuntu@<PUBLIC_IP>:/etc/nginx/ssl/novnc.crt \
  novnc-selfsigned.crt
```
