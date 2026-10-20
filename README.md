# novnc-desktop

[![Lint](https://github.com/markcallen/novnc-desktop/actions/workflows/lint.yml/badge.svg)](https://github.com/markcallen/novnc-desktop/actions/workflows/lint.yml)
[![Ansible Lint](https://github.com/markcallen/novnc-desktop/actions/workflows/ansible-lint.yml/badge.svg)](https://github.com/markcallen/novnc-desktop/actions/workflows/ansible-lint.yml)
[![Publish](https://github.com/markcallen/novnc-desktop/actions/workflows/publish.yml/badge.svg)](https://github.com/markcallen/novnc-desktop/actions/workflows/publish.yml)
[![License](https://img.shields.io/github/license/markcallen/novnc-desktop)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/markcallen/novnc-desktop)](https://github.com/markcallen/novnc-desktop/releases)

An Ansible role and a ready-to-launch AMI for a browser-accessible Linux desktop on Ubuntu 24.04 LTS. Access uses a time-limited URL over HTTPS; no VNC client or port forwarding is needed.

## Requirements

Choose the path that fits your use:

| Path                                          | What you need                                                                                                                                                                 |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Pre-built AMI](#pre-built-amis)              | An AWS account, an EC2 key pair, a public subnet, and a security group allowing SSH from your IP and HTTPS on port 443. The AWS CLI is optional if you launch in the console. |
| [Ansible role](#ansible-role-usage)           | Ansible 2.13+ on your control machine and SSH access to an Ubuntu 24.04 LTS host with sudo privileges. Allow ports 80 and 443 to reach the host.                              |
| [Developer and smoke tests](#developer-setup) | A local checkout, Node.js 25, pnpm 10, Python 3.12+, Ansible, and Terraform 1.14+. AWS credentials are required for the EC2 smoke workflow.                                   |

Launching a released AMI requires no local Node, pnpm, Terraform, or Ansible installation. Provisioning an existing host with Ansible requires no Node or Terraform installation.

## Install dependencies

For an existing Ubuntu host, install the role and its required collections on your Ansible control machine. Replace `v0.2.4` with the tag you choose from [Releases](https://github.com/markcallen/novnc-desktop/releases):

```sh
ansible-galaxy role install git+https://github.com/markcallen/novnc-desktop.git,v0.2.4,markcallen.novnc_desktop --roles-path ./roles
ansible-galaxy collection install ansible.utils community.general
```

Use `markcallen.novnc_desktop` in your playbook, as shown below. The [pre-built AMI](#pre-built-amis) needs no local dependencies.

## Pre-built AMIs

Public AMIs contain the Elementary desktop. Openbox remains available through a private build. AMI IDs differ by region; use the AWS lookup below to find one. See [Releases](https://github.com/markcallen/novnc-desktop/releases) for source release history.

The AMI is already provisioned. It boots with a self-signed HTTPS certificate and generates a desktop access URL using its public hostname or IP. You can add a trusted certificate later.

### Launch workflow

1. In the EC2 console, search **Public AMIs** for `novnc-desktop-ubuntu-24.04-elementary-` owned by AWS account `819363892004`, or use the AWS CLI to print the newest matching public AMI ID in your region:

   ```sh
   aws ec2 describe-images \
     --region us-east-1 \
     --owners 819363892004 \
     --filters 'Name=name,Values=novnc-desktop-ubuntu-24.04-elementary-*' 'Name=state,Values=available' \
     --query 'sort_by(Images[?Public==`true`], &CreationDate)[-1].ImageId' \
     --output text
   ```

   Change `us-east-1` to your region. If the result is `None`, no matching public AMI is available there.

2. Launch that AMI with a `t3.medium` instance, an SSH key pair, a public subnet, and a public IP. Allow inbound TCP 22 from your IP and TCP 443 from the browsers that will use the desktop. The AMI's `ubuntu` user accepts your SSH key.
3. Once the instance is running, get a time-limited access URL and open it in your browser:

   ```sh
   ssh -i /path/to/key.pem ubuntu@<public-ip> novnc-desktop-url
   ```

The URL remains usable until it expires (8 hours by default), including after it has been opened. Treat it as a credential. The default certificate is self-signed, so your browser will show a certificate warning. For a trusted certificate, follow [Launch from an AMI](docs/launch-from-ami.md): set up a domain, Route53 permissions, and the supplied [user-data script](examples/user-metadata-certbot-example.sh). That guide also has the full AWS CLI launch and cleanup commands. Stop or terminate the instance when finished to avoid ongoing EC2 charges.

## Building AMIs

To build both variants privately or publish Elementary:

```sh
# Build private AMIs (default)
./scripts/build-ami.sh

# Build a public Elementary AMI for distribution
AMI_PUBLIC=true AMI_ENVIRONMENT=production ./scripts/build-ami.sh

# Custom prefix and region
AMI_NAME_PREFIX=my-novnc AWS_REGION=us-west-2 AMI_PUBLIC=true ./scripts/build-ami.sh
```

| Variable          | Default                      | Description                                                   |
| ----------------- | ---------------------------- | ------------------------------------------------------------- |
| `AWS_REGION`      | `us-east-1`                  | AWS region to build in                                        |
| `INSTANCE_TYPE`   | `t3.medium`                  | EC2 instance type for the build                               |
| `AMI_NAME_PREFIX` | `novnc-desktop-ubuntu-24.04` | Prefix applied to both openbox and elementary names           |
| `USE_CERTBOT`     | `false`                      | Run certbot at bake time (only for private AMIs)              |
| `AMI_PUBLIC`      | `false`                      | Build and publish only the Elementary AMI when `true`         |
| `AMI_ENVIRONMENT` | `test`                       | `Environment` tag value; set `production` for public releases |

Building requires Packer, Ansible, and AWS credentials with EC2 and AMI permissions. Developers can use `pnpm build:ami:public` for the same public command. See [Building AMIs with Packer](docs/packer-build.md) for prerequisites and advanced options.

## Ansible role usage

### Use the released role in your playbook

Add this to your `requirements.yml`:

```yaml
roles:
  - name: markcallen.novnc_desktop
    src: https://github.com/markcallen/novnc-desktop
    scm: git
    version: v0.2.4

collections:
  - name: ansible.utils
    version: '>=2.0.0'
  - name: community.general
```

Save this playbook as `playbook.yml`:

```yaml
---
- name: Provision noVNC desktop
  hosts: all
  become: true
  roles:
    - markcallen.novnc_desktop
```

Then install and run it. Replace `YOUR_HOST` with the host's reachable IP or DNS name:

```sh
ansible-galaxy role install -r requirements.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbook.yml -i 'YOUR_HOST,' -u ubuntu --private-key ~/.ssh/key.pem
```

### Clone and run directly

```sh
git clone https://github.com/markcallen/novnc-desktop.git
cd novnc-desktop
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml -i 'YOUR_HOST,' -u ubuntu --private-key ~/.ssh/key.pem
```

This runs the current checkout. To reproduce a release, check out its tag before running the playbook.

Key variables:

| Variable                    | Default    | Description                                                    |
| --------------------------- | ---------- | -------------------------------------------------------------- |
| `desktop_type`              | `openbox`  | Desktop environment: `openbox`, `elementary`                   |
| `vnc_user`                  | `ubuntu`   | OS user that owns the desktop session                          |
| `vnc_geometry`              | `1280x720` | Screen resolution                                              |
| `auth_token_ttl_seconds`    | `28800`    | Token lifetime in seconds (default 8 hours)                    |
| `novnc_http_port`           | `80`       | Public HTTP port that redirects to HTTPS                       |
| `novnc_https_port`          | `443`      | Public HTTPS port served by nginx                              |
| `novnc_base_url`            | Host URL   | Public HTTPS address used in generated access URLs             |
| `use_certbot`               | `false`    | Attempt Let's Encrypt certificate acquisition on `80/443` only |
| `tls_domain`                | Host name  | Public domain for Let's Encrypt                                |
| `letsencrypt_email`         | Empty      | Registration email for Let's Encrypt                           |
| `smoke_test_marker_enabled` | `false`    | Render green xterm marker for canvas verification              |

Use `-e 'desktop_type=elementary'` to choose Elementary. To request a trusted certificate, add `-e 'use_certbot=true tls_domain=desktop.example.com letsencrypt_email=you@example.com novnc_base_url=https://desktop.example.com'` to the playbook command. The domain must resolve publicly, and HTTP port 80 must be reachable for the certificate challenge. The default uses a self-signed certificate.

After provisioning, run `ssh -i ~/.ssh/key.pem ubuntu@YOUR_HOST novnc-desktop-url` to get a time-limited HTTPS access URL. The URL can be reused until it expires; keep it private.

### novnc-desktop meta-service

The role installs a `novnc-desktop.service` systemd meta-service that manages the full stack (TigerVNC, noVNC, novnc-auth, nginx) as a single unit:

```sh
# Check if the full stack is up
systemctl is-active novnc-desktop

# Start or stop the entire stack
systemctl start novnc-desktop
systemctl stop novnc-desktop
```

Automation tools and user-data scripts should target `novnc-desktop` rather than individual services.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Developer setup

Clone the repository, select the Node version in `.nvmrc` with [nvm](https://github.com/nvm-sh/nvm), and install the pinned pnpm dependencies. Python 3.12+, Ansible, `ansible-lint`, and `yamllint` are needed for the Ansible checks; Terraform 1.14+ and AWS credentials are needed only for the EC2 smoke workflow.

```sh
git clone https://github.com/markcallen/novnc-desktop.git
cd novnc-desktop
nvm install
nvm use
corepack enable
pnpm install --frozen-lockfile
ansible-galaxy collection install -r requirements.yml
pnpm run test:unit
```

For the same lint checks as CI, install `ansible-lint` and `yamllint` using your Python environment, then run:

```sh
pnpm run lint
pnpm run prettier
yamllint .
ansible-lint
ansible-playbook --syntax-check site.yml
```

## Smoke test workflow

The Playwright suite uses a real EC2 instance and incurs AWS charges. Install Chromium once with `pnpm exec playwright install chromium`, configure AWS credentials, and ensure Terraform 1.14+, `jq`, SSH, and Ansible are available. The Terraform configuration generates a dedicated SSH key pair; no existing EC2 key pair is needed.

### 1. Configure Terraform variables

```sh
cp smoke/ec2/terraform.tfvars.example smoke/ec2/terraform.tfvars
```

Edit `smoke/ec2/terraform.tfvars` and fill in your values:

| Variable     | Description                                                            |
| ------------ | ---------------------------------------------------------------------- |
| `aws_region` | AWS region (e.g. `us-east-1`)                                          |
| `stack_name` | Logical name for this stack (e.g. `smoke`)                             |
| `ssh_cidr`   | Your public IP in `/32` form — `curl -s https://checkip.amazonaws.com` |
| `http_cidr`  | CIDR for HTTP access; restrict to your IP for self-signed TLS          |
| `https_cidr` | CIDR for HTTPS access                                                  |

### 2. Provision and test an Ubuntu host

```sh
pnpm infra:up
pnpm provision:openbox
pnpm infra:status
pnpm test
pnpm infra:down
```

`infra:up` creates the instance and writes `.smoke-state/state.json`; `provision:openbox` runs Ansible. Use `pnpm provision:elementary` instead to test Pantheon. Always run `pnpm infra:down` when finished, including after a failed test.

### 3. Test an existing AMI instead

After configuring `terraform.tfvars`, replace the provision steps with one of these commands. The AMI is already provisioned, so `infra:ami` verifies it and writes smoke state without an Ansible run:

```sh
# In the AMI owner's AWS account, discover the latest production Elementary AMI.
pnpm infra:ami --variant elementary --public

# In another AWS account, pass the released AMI ID for your region explicitly.
pnpm infra:ami --variant elementary ami-XXXXXXXX

pnpm test
pnpm infra:down
```

`--public` searches production-tagged AMIs owned by the current AWS account. For a trusted-certificate smoke run, add `--domain YOUR_ROUTE53_ZONE --certbot-email YOU@example.com` and provide the IAM instance profile described in [Route53 IAM setup](docs/route53-iam-setup.md). Specifying a domain enables certbot; the default uses the AMI's self-signed certificate.

Useful `infra:ami` options:

| Flag                            | Description                                                                                   |
| ------------------------------- | --------------------------------------------------------------------------------------------- |
| `--domain <zone>`               | Route53 parent zone; script creates a unique hostname under it and enables certbot by default |
| `--certbot-email <email>`       | Passes certbot registration/renewal email to `novnc-setup-tls`                                |
| `--iam-instance-profile <name>` | Profile with Route53 permissions for certbot                                                  |
| `--use-certbot`                 | Force-enable certbot on first boot (requires `--domain`)                                      |
| `--no-certbot`                  | Force-disable certbot on first boot even when `--domain` is set                               |
| `--public`                      | Resolve an owned production-tagged AMI                                                        |

For custom-port testing on a fresh Ubuntu host, use `pnpm provision:elementary:custom-ports` after `pnpm infra:up`; it configures ports `8080/8443` and updates the smoke state before `pnpm test`.
