# Packer Quick Start Guide

## Problem Solved

The Packer setup fixes the `E: dpkg was interrupted` error that was occurring during Ansible execution. This error happens because the package manager state is corrupted in the build environment.

## Solution

The new Packer configuration includes **explicit dpkg state repair** before running Ansible:

1. **Fixes broken dpkg state** with `dpkg --configure -a`
2. **Waits for all apt locks** to be released
3. **Installs Ansible** in a clean environment
4. **Runs your playbook** with guaranteed clean state
5. **Optimizes the final image** by cleaning up build artifacts

## Requirements

```bash
# Install Packer
# macOS with Homebrew:
brew install packer

# Or download from https://www.packer.io/downloads
```

```bash
# Verify Packer installation
packer version
```

**AWS Credentials**: Set up your AWS credentials (one of):

```bash
# Option 1: Environment variables
export AWS_ACCESS_KEY_ID=your-access-key
export AWS_SECRET_ACCESS_KEY=your-secret-key

# Option 2: AWS CLI profile (automatic)
aws configure

# Option 3: IAM role (when running from EC2)
```

## Basic Usage

### Build with Defaults

```bash
cd /home/marka/src/novnc-desktop
./build-ami.sh
```

This builds an AMI named `novnc-desktop-ubuntu-24.04-<timestamp>` in `us-east-1` using a `t3.medium` instance.

### Custom Build

```bash
AWS_REGION=us-west-2 INSTANCE_TYPE=t3.large ./build-ami.sh
```

### Manual Packer Build

```bash
packer build packer.pkr.hcl

# With custom variables:
packer build \
  -var 'aws_region=us-west-2' \
  -var 'instance_type=t3.large' \
  packer.pkr.hcl
```

## Build Timeline

A typical build takes **10-15 minutes**:

- **1-2 min**: Launch EC2 instance
- **2-3 min**: Wait for SSH readiness
- **1-2 min**: Fix dpkg state and install Ansible
- **5-8 min**: Run Ansible playbook
- **1-2 min**: Cleanup and optimize
- **1 min**: Create and tag AMI

## What Gets Built

The Packer process creates:

- **AMI**: A ready-to-use image with:
  - Ubuntu 24.04 LTS base
  - TigerVNC server
  - noVNC web interface
  - Nginx reverse proxy
  - User authentication system
  - Desktop environment (Elementary + Openbox)

- **Tags Applied**:
  - `Name`: Your chosen AMI name
  - `OS`: Ubuntu 24.04 LTS
  - `BuildTool`: Packer
  - `BuildDate`: Timestamp when built
  - `Description`: What the AMI contains

## Validating the Build

After the build completes, you'll see:

```
==> novnc-desktop-ubuntu-24.04.amazon-ebs.ubuntu: Creating the AMI: novnc-desktop-ubuntu-24.04-XXXXX
==> novnc-desktop-ubuntu-24.04.amazon-ebs.ubuntu: AMI: ami-0123456789abcdef
==> novnc-desktop-ubuntu-24.04.amazon-ebs.ubuntu: Created snapshot snap-123456789
Build 'novnc-desktop-ubuntu-24.04.amazon-ebs.ubuntu' finished.

==> Builds finished. The artifacts of successful builds are:
--> novnc-desktop-ubuntu-24.04.amazon-ebs.ubuntu: AMIs were created:
us-east-1: ami-0123456789abcdef
```

Launch this AMI to test:

```bash
# Launch an instance from the AMI
aws ec2 run-instances \
  --image-id ami-0123456789abcdef \
  --instance-type t3.medium \
  --key-name your-keypair \
  --region us-east-1

# SSH into the instance
ssh -i your-key.pem ubuntu@<instance-ip>

# Verify services are running
sudo systemctl status tigervnc-standalone-server@:1
sudo systemctl status novnc
sudo systemctl status nginx

# Access via browser
# https://<instance-ip>:6080
```

## Files Created

```
/home/marka/src/novnc-desktop/
├── packer.pkr.hcl           # Packer configuration
├── build-ami.sh             # Build script
└── docs/
    ├── packer-build.md      # Detailed documentation
    └── packer-quick-start.md # This file
```

## Troubleshooting

### "dpkg was interrupted" error (Old Issue)

**This is now fixed!** The new Packer config includes `dpkg --configure -a` to repair the package state.

### Build Timeout

Increase the SSH timeout in `packer.pkr.hcl`:

```hcl
ssh_timeout = "15m"  # Change from 10m to 15m
```

### Ansible Fails on Specific Task

Check the Ansible output in the build log:

```bash
# Look for the failing task name and error
# Common issues:
# - Network timeout: use larger instance type
# - Out of disk space: increase root_volume_size
# - Package not found: check Ubuntu 24.04 package names
```

### Cannot Access AWS

Verify credentials:

```bash
aws sts get-caller-identity

# Should return your account info, not an error
```

## Cost Considerations

Typical build costs:

- **t3.small**: $0.02-0.04 per build (fastest: 5-8 min)
- **t3.medium**: $0.03-0.06 per build (balanced: 10-15 min) ← **default**
- **t3.large**: $0.05-0.10 per build (fastest: 8-12 min)

Plus minimal EBS snapshot storage (~$0.05/month).

Use `AWS_REGION` to select cheaper regions (us-east-1 is generally cheapest).

## Next Steps

1. **Build the AMI**: `./build-ami.sh`
2. **Launch an instance**: From the AWS console or CLI
3. **Test the environment**: Access via SSH and verify services
4. **Use in production**: Tag, document, and share the AMI

## More Information

See [packer-build.md](packer-build.md) for:

- Detailed configuration options
- Advanced troubleshooting
- CI/CD integration examples
- AWS permissions requirements
