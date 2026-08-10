# Building AMIs with Packer

This guide explains how to build an AWS AMI for the noVNC Desktop using Packer.

## Prerequisites

1. **Packer**: Install from https://www.packer.io/downloads (v1.8.0 or later)
2. **AWS Credentials**: Configure AWS credentials with permissions to create AMIs and EC2 instances
   - Set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as environment variables, or
   - Use `aws configure` to set up your AWS CLI profile
3. **Public AMIs — Disable Block Public Access**: If you intend to build public AMIs (`AMI_PUBLIC=true`), AWS requires that "Block Public Access for AMIs" is disabled at the account level in each target region. Run this once per region before building:

   ```bash
   aws ec2 disable-image-block-public-access --region us-east-1
   ```

   Without this, Packer will build and then deregister the AMI with the error `OperationNotPermitted: block public access for AMIs is enabled`.

4. **AWS Permissions**: The IAM user/role must have permissions for:
   - `ec2:CreateImage`
   - `ec2:CreateSnapshot`
   - `ec2:DescribeImages`
   - `ec2:DescribeInstances`
   - `ec2:DescribeSecurityGroups`
   - `ec2:CreateSecurityGroup`
   - `ec2:AuthorizeSecurityGroupIngress`
   - `ec2:RunInstances`
   - `ec2:TerminateInstances`
   - `ec2:StopInstances`
   - `ec2:StartInstances`
   - `ec2:DescribeSnapshots`
   - `ec2:DeleteSnapshot`
   - `ec2:CreateTags`

## Quick Start

### Basic Build

Build an AMI with default settings (us-east-1, t3.medium instance type):

```bash
./scripts/build-ami.sh
```

### Custom Build

Build with custom AWS region and instance type:

```bash
AWS_REGION=us-west-2 INSTANCE_TYPE=t3.large ./scripts/build-ami.sh
```

Or manually with Packer:

```bash
packer build \
  -var 'aws_region=us-west-2' \
  -var 'instance_type=t3.large' \
  -var 'ami_name_prefix=novnc-desktop-custom' \
  packer.pkr.hcl
```

## What the Build Does

The Packer configuration (`packer.pkr.hcl`) performs these steps:

### 1. **Base Image**

- Uses the latest Ubuntu 24.04 LTS AMI from Canonical
- Automatically discovers the newest available image

### 2. **Fix dpkg/apt State and Install Dependencies**

- Runs `dpkg --configure -a` to resolve any interrupted package configurations
- Cleans apt cache and removes stale locks
- Installs Python 3, pip, git, and curl (required for Ansible to run)
- This prevents the "E: dpkg was interrupted" error that was causing failures

### 3. **Run Ansible Provisioner**

- Uses Packer's built-in `ansible` provisioner running on the build host
- Connects to the EC2 instance over SSH as the `ubuntu` user
- Installs Galaxy requirements from `packer-requirements.yml` (pins `markcallen.novnc_desktop` role)
- Executes `packer-playbook.yml` which applies the `markcallen.novnc_desktop` role
- Sets `ansible_python_interpreter=/usr/bin/python3` to use the system Python

### 4. **Optimize Image**

- Cleans up apt cache and temporary files
- Removes build artifacts
- Truncates logs to reduce image size
- Clears shell history

## Configuration Variables

Edit `packer.pkr.hcl` or pass variables via the `-var` flag:

| Variable           | Default                      | Description                                                                                          |
| ------------------ | ---------------------------- | ---------------------------------------------------------------------------------------------------- |
| `aws_region`       | `us-east-1`                  | AWS region for the build                                                                             |
| `instance_type`    | `t3.medium`                  | EC2 instance type (t3.small for faster/cheaper builds, t3.large for faster builds)                   |
| `root_volume_size` | `20`                         | Root volume size in GB                                                                               |
| `ami_name_prefix`  | `novnc-desktop-ubuntu-24.04` | Prefix applied to openbox AMI names                                                                  |
| `use_certbot`      | `false`                      | Run certbot at bake time; leave false for public AMIs that use user-data for TLS                     |
| `ami_public`       | `false`                      | Set launch permissions to allow all AWS accounts (`ami_groups = ["all"]`)                            |
| `ami_environment`  | `test`                       | Value for the `Environment` tag; use `test` for smoke-discoverable builds, `production` for releases |
| `novnc_http_port`  | `80`                         | HTTP port nginx listens on. Must be `80` when using Let's Encrypt (HTTP-01 challenge)                |
| `novnc_https_port` | `443`                        | HTTPS port nginx listens on. Use `8443` for non-standard deployments                                 |

See [custom-ports.md](./custom-ports.md) for a full guide on building and launching AMIs on ports 8080/8443 with and without certbot.

See [route53-iam-setup.md](./route53-iam-setup.md) for the IAM role required to run `novnc-setup-tls` with Let's Encrypt on any instance launched from a public AMI.

## Instance Type Selection

- **t3.small**: Cheapest, ~5-10 minutes (minimal overhead)
- **t3.medium**: Balanced (default), ~10-15 minutes
- **t3.large**: Faster, ~8-12 minutes (but more expensive)

## Troubleshooting

### Build Fails with "dpkg was interrupted"

This is now handled automatically by the new Packer configuration. If you still see this error:

1. Ensure the base image is clean (use a fresh Ubuntu 24.04 AMI)
2. Check that no other builds are using the same base image
3. Try a different instance type with more resources (e.g., t3.large)

### Build Fails on Ansible Task

Check the Ansible output in the Packer logs:

1. Look for the task name and error message
2. Verify the Ansible playbook works locally:
   ```bash
   sudo ansible-playbook -i 'localhost,' -c local site.yml
   ```
3. Fix the issue in the playbook and rebuild

### SSH Connection Timeout

If Packer times out waiting for SSH:

1. Increase the SSH timeout in `packer.pkr.hcl`:
   ```hcl
   ssh_timeout = "15m"
   ```
2. Use a larger instance type (t3.medium or larger)
3. Check your AWS VPC security group allows SSH from Packer's IP

### Build Takes Too Long

- Use a larger instance type: `INSTANCE_TYPE=t3.large ./scripts/build-ami.sh`
- Increase the EBS volume type to `gp3` (already configured)
- Check your internet connection (Ubuntu packages are being downloaded)

## Validating the AMI

After a successful build:

1. **Launch Instance from the AMI**:

   ```bash
   aws ec2 run-instances \
     --image-id ami-xxxxx \
     --instance-type t3.medium \
     --region us-east-1 \
     --key-name your-keypair
   ```

2. **Connect and Test**:

   ```bash
   ssh -i your-key.pem ubuntu@instance-ip
   # Check that VNC, noVNC, and nginx are running
   sudo systemctl status tigervnc-standalone-server@:1
   sudo systemctl status novnc
   sudo systemctl status nginx
   ```

3. **Access noVNC**:
   - Open `https://<instance-ip>:6080` in your browser
   - You should see the noVNC login page

## Cleanup

After building, you can save costs by:

1. **Delete Intermediate Snapshots** (done automatically)
2. **Deregister Unused AMIs**:
   ```bash
   aws ec2 deregister-image --image-id ami-xxxxx
   ```
3. **Delete Snapshots**:
   ```bash
   aws ec2 delete-snapshot --snapshot-id snap-xxxxx
   ```

## CI/CD Integration

To use this in GitHub Actions, add a workflow file `.github/workflows/build-ami.yml`:

```yaml
name: Build noVNC Desktop AMI

on:
  workflow_dispatch:
  push:
    branches: [main]
    paths:
      - 'packer.pkr.hcl'
      - 'roles/**'
      - 'site.yml'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Packer
        uses: hashicorp/setup-packer@main

      - name: Validate Packer
        run: packer validate packer.pkr.hcl

      - name: Build AMI
        run: ./scripts/build-ami.sh
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          AWS_REGION: us-east-1
          AMI_NAME_PREFIX: novnc-desktop-${{ github.ref_name }}-${{ github.run_number }}
```

## Additional Resources

- [Packer Documentation](https://www.packer.io/docs)
- [Packer AWS Builder](https://www.packer.io/docs/builders/amazon/ebs)
- [Packer Shell Provisioner](https://www.packer.io/docs/provisioners/shell)
- [Packer Ansible Provisioner](https://www.packer.io/docs/provisioners/ansible/ansible)
