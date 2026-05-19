# Launching a noVNC Desktop from an AMI

This guide walks through launching a pre-built noVNC Desktop AMI using the AWS CLI,
including the required IAM permissions, security group setup, and TLS configuration
via EC2 user-data.

## Prerequisites

- AWS CLI v2 installed and configured (`aws configure`)
- A domain name with DNS you control (required for TLS via Let's Encrypt)
- The AMI ID for your region — see [GitHub Releases](https://github.com/markcallen/novnc-desktop/releases)

## Required IAM Permissions

The IAM user or role running these commands needs the following EC2 permissions.
Save this as a policy document and attach it to your user or role.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "NoVNCDesktopLaunch",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeImages",
        "ec2:DescribeKeyPairs",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:DescribeSecurityGroups",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:CreateTags",
        "ec2:TerminateInstances",
        "ec2:StopInstances",
        "ec2:StartInstances",
        "ec2:AllocateAddress",
        "ec2:ReleaseAddress",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress",
        "ec2:DescribeAddresses"
      ],
      "Resource": "*"
    }
  ]
}
```

> **Note**: `ec2:CreateKeyPair` and `ec2:DeleteKeyPair` are only needed if you create
> a new key pair. Omit them if you supply an existing key pair name.
> The `ec2:Allocate/Release/AssociateAddress` actions are only needed if you use
> an Elastic IP (see the [Using an Elastic IP](#using-an-elastic-ip-recommended-for-production) section).

## Step 1 — Find Your VPC and Subnet

```bash
# List available VPCs (use your default VPC or an existing one)
aws ec2 describe-vpcs \
  --query 'Vpcs[?IsDefault==`true`].[VpcId,CidrBlock]' \
  --output table

# List subnets in the VPC (pick one with a public route)
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXX" \
  --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table
```

## Step 2 — Create a Security Group

```bash
VPC_ID=vpc-XXXXXXXX   # replace with your VPC ID
MY_IP=$(curl -s https://checkip.amazonaws.com)/32

SG_ID=$(aws ec2 create-security-group \
  --group-name novnc-desktop-sg \
  --description "noVNC Desktop access" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' \
  --output text)

echo "Security group: $SG_ID"

# SSH — restrict to your IP
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "$MY_IP"

# HTTP — needed for Let's Encrypt certificate validation
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# HTTPS — noVNC desktop access
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
```

> After certificate validation succeeds you can revoke the port 80 rule if you no
> longer need HTTP.

## Step 3 — Create an SSH Key Pair

Skip this step if you already have a key pair you want to use.

```bash
aws ec2 create-key-pair \
  --key-name novnc-desktop-key \
  --query 'KeyMaterial' \
  --output text > novnc-desktop-key.pem

chmod 600 novnc-desktop-key.pem
```

## Step 4 — Prepare the User-Data Script

Create a file called `user-data.sh` with your domain and email at the top,
followed by the contents of `examples/user-metadata-certbot-example.sh`:

```bash
cat > user-data.sh <<'EOF'
#!/bin/bash
export CERTBOT_DOMAIN=myapp.example.com
export CERTBOT_EMAIL=admin@example.com
export NOVNC_HTTPS_PORT=443
EOF
cat examples/user-metadata-certbot-example.sh >> user-data.sh
```

> **DNS must be configured before launch.** Create an `A` record pointing
> `myapp.example.com` to the instance's public IP. Because the IP is only known
> after launch, the typical workflow is:
>
> 1. Launch without user-data first to get the public IP.
> 2. Create the DNS record.
> 3. Wait for propagation (`dig +short myapp.example.com`).
> 4. SSH in and run `sudo CERTBOT_DOMAIN=myapp.example.com /usr/local/bin/novnc-setup-tls`.
>
> Alternatively, use an Elastic IP — allocate it before launch and assign it,
> then create the DNS record pointing to that IP.

## Step 5 — Launch the Instance

```bash
AMI_ID=ami-XXXXXXXX   # replace with the AMI ID from GitHub Releases
SUBNET_ID=subnet-XXXXXXXX

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.medium \
  --key-name novnc-desktop-key \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --user-data file://user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=novnc-desktop}]' \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance: $INSTANCE_ID"
```

## Step 6 — Wait for the Instance to Be Ready

```bash
# Wait until running
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# Get the public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Public IP: $PUBLIC_IP"
```

## Step 7 — Monitor Setup Progress

The TLS setup runs automatically via user-data. It typically completes within
2–4 minutes of the instance reaching the running state.

```bash
# SSH into the instance
ssh -i novnc-desktop-key.pem ubuntu@"$PUBLIC_IP"

# Follow the TLS setup log
sudo tail -f /var/log/novnc-setup-tls.log

# Check the full stack status
sudo systemctl status novnc-desktop

# Once complete, get your signed access URL
sudo novnc-desktop-url
```

The URL output looks like:

```
https://myapp.example.com/access?token=<signed-token>
```

Open it in a browser to access the desktop. The token is valid for 8 hours by default.

## Step 8 — Clean Up

```bash
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
aws ec2 delete-security-group --group-id "$SG_ID"
aws ec2 delete-key-pair --key-name novnc-desktop-key
rm novnc-desktop-key.pem
```

## Using an Elastic IP (Recommended for Production)

An Elastic IP lets you set the DNS record before launch and reattach it to a
replacement instance if needed.

```bash
# Allocate an Elastic IP
ALLOCATION_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --query 'AllocationId' \
  --output text)

ELASTIC_IP=$(aws ec2 describe-addresses \
  --allocation-ids "$ALLOCATION_ID" \
  --query 'Addresses[0].PublicIp' \
  --output text)

echo "Elastic IP: $ELASTIC_IP"

# Create your DNS A record pointing myapp.example.com → $ELASTIC_IP
# Then launch the instance (Step 5), then associate:

aws ec2 associate-address \
  --instance-id "$INSTANCE_ID" \
  --allocation-id "$ALLOCATION_ID"
```

To release the Elastic IP during cleanup:

```bash
aws ec2 disassociate-address --association-id <association-id>
aws ec2 release-address --allocation-id "$ALLOCATION_ID"
```

## Running the TLS Setup Manually

If you launched without user-data, or want to re-run the setup:

```bash
ssh -i novnc-desktop-key.pem ubuntu@"$PUBLIC_IP"

sudo CERTBOT_DOMAIN=myapp.example.com \
     CERTBOT_EMAIL=admin@example.com \
     /usr/local/bin/novnc-setup-tls

sudo novnc-desktop-url
```

## Troubleshooting

### Certificate acquisition fails

Ensure:

- The DNS `A` record for your domain resolves to the instance's public IP (`dig +short myapp.example.com`).
- Port 80 is open in the security group for inbound traffic from `0.0.0.0/0`.
- The instance is fully started (`aws ec2 describe-instance-status`).

### novnc-desktop service is not active

```bash
sudo systemctl status novnc-desktop
sudo journalctl -u novnc-desktop -n 50
sudo journalctl -u nginx -n 30
sudo journalctl -u novnc-auth -n 30
```

### novnc-desktop-url produces the wrong domain

The auth service `base_url` is updated by `novnc-setup-tls`. If you ran the setup
successfully, verify the config was updated:

```bash
sudo cat /etc/novnc-auth/config.json
```

If `base_url` still shows the old placeholder, re-run `novnc-setup-tls`.
