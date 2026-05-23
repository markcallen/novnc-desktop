# Route53 IAM Setup for Let's Encrypt DNS-01

The `novnc-setup-tls` script on public AMIs uses certbot's `dns-route53` plugin
to obtain Let's Encrypt certificates. This plugin creates and removes a
`_acme-challenge` TXT record in Route53 to prove domain ownership — no inbound
port 80 required.

The EC2 instance must have an IAM role attached with permission to manage that
TXT record in Route53.

## Quick setup (recommended)

Use the helper script to create/update IAM resources and verify Route53:

```bash
bash smoke/scripts/setup-certbot-route53.sh --zone smoke.markcallen.dev
```

The script is idempotent and ensures:

- IAM policy `novnc-certbot-route53`
- IAM role `novnc-desktop-certbot`
- IAM instance profile `novnc-desktop-certbot`
- Route53 hosted zone exists in the current account

You can also verify a specific domain (finds matching parent zone):

```bash
bash smoke/scripts/setup-certbot-route53.sh --domain myapp.example.com
```

## Manual setup (advanced / fallback)

### Step 1 — Create the IAM policy

Save the following as `novnc-certbot-route53-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CertbotRoute53",
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:GetChange",
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": "*"
    }
  ]
}
```

Create the policy:

```bash
POLICY_ARN=$(aws iam create-policy \
  --policy-name novnc-certbot-route53 \
  --policy-document file://novnc-certbot-route53-policy.json \
  --query 'Policy.Arn' \
  --output text)

echo "Policy ARN: $POLICY_ARN"
```

> To restrict the policy to a specific hosted zone, replace `"Resource": "*"`
> with the zone ARN:
> `"Resource": "arn:aws:route53:::hostedzone/ZXXXXXXXXXXXXX"`

### Step 2 — Create the IAM role

```bash
# Create a trust policy allowing EC2 instances to assume this role
cat > trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

ROLE_ARN=$(aws iam create-role \
  --role-name novnc-desktop-certbot \
  --assume-role-policy-document file://trust-policy.json \
  --query 'Role.Arn' \
  --output text)

echo "Role ARN: $ROLE_ARN"

# Attach the certbot policy
aws iam attach-role-policy \
  --role-name novnc-desktop-certbot \
  --policy-arn "$POLICY_ARN"

# Create an instance profile and add the role to it
aws iam create-instance-profile \
  --instance-profile-name novnc-desktop-certbot

aws iam add-role-to-instance-profile \
  --instance-profile-name novnc-desktop-certbot \
  --role-name novnc-desktop-certbot
```

### Step 3 — Attach the instance profile at launch

Pass `--iam-instance-profile` when running the instance:

```bash
aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.medium \
  --key-name novnc-desktop-key \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --iam-instance-profile Name=novnc-desktop-certbot \
  --user-data file://user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=novnc-desktop}]' \
  --query 'Instances[0].InstanceId' \
  --output text
```

### Step 4 — Verify the hosted zone

The domain you pass as `CERTBOT_DOMAIN` must have a public hosted zone in
Route53 in the **same AWS account** as the instance. Certbot discovers the zone
automatically by listing hosted zones and matching against the domain.

```bash
# Confirm the zone exists
aws route53 list-hosted-zones \
  --query 'HostedZones[?Name==`myapp.example.com.`].[Id,Name]' \
  --output table

# If the zone covers the apex domain, a subdomain record works automatically
aws route53 list-hosted-zones \
  --query 'HostedZones[?Name==`example.com.`].[Id,Name]' \
  --output table
```

> The hosted zone does **not** need to be the zone for the exact domain —
> certbot walks up the DNS tree to find the correct zone. A zone for
> `example.com` will handle `myapp.example.com`.

## Security group requirements

DNS-01 does not require port 80 to be open. The only inbound ports needed are:

| Port          | Protocol | Purpose                                |
| ------------- | -------- | -------------------------------------- |
| 22            | TCP      | SSH admin access (restrict to your IP) |
| 8443 (or 443) | TCP      | HTTPS desktop access                   |

Port 80 is not needed and should be omitted from the security group.

## Terraform example

```hcl
resource "aws_iam_role" "novnc_certbot" {
  name = "novnc-desktop-certbot"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "novnc_certbot_route53" {
  name = "certbot-route53"
  role = aws_iam_role.novnc_certbot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CertbotRoute53"
      Effect = "Allow"
      Action = [
        "route53:ListHostedZones",
        "route53:GetChange",
        "route53:ChangeResourceRecordSets",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "novnc_certbot" {
  name = "novnc-desktop-certbot"
  role = aws_iam_role.novnc_certbot.name
}

resource "aws_instance" "novnc" {
  ami                  = var.novnc_ami_id
  instance_type        = "t3.medium"
  iam_instance_profile = aws_iam_instance_profile.novnc_certbot.name
  # ...
}
```
