# novnc-desktop

[![Lint](https://github.com/markcallen/novnc-desktop/actions/workflows/lint.yml/badge.svg)](https://github.com/markcallen/novnc-desktop/actions/workflows/lint.yml)
[![Ansible Lint](https://github.com/markcallen/novnc-desktop/actions/workflows/ansible-lint.yml/badge.svg)](https://github.com/markcallen/novnc-desktop/actions/workflows/ansible-lint.yml)
[![Publish](https://github.com/markcallen/novnc-desktop/actions/workflows/publish.yml/badge.svg)](https://github.com/markcallen/novnc-desktop/actions/workflows/publish.yml)
[![License](https://img.shields.io/github/license/markcallen/novnc-desktop)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/markcallen/novnc-desktop)](https://github.com/markcallen/novnc-desktop/releases)

An Ansible role that provisions a secure, browser-accessible Linux desktop on any Ubuntu 24.04 LTS host. Access is token-secured over HTTPS — no VNC client, no password prompt, no port forwarding required.

## Requirements

- Ansible 2.13+
- Terraform 1.14+
- Node.js (via nvm — see below)
- pnpm 10
- AWS credentials configured (`~/.aws/credentials` or environment variables)

## Node.js setup with nvm

This project ships a `.nvmrc` pinned to Node.js v25. Install and activate it:

```sh
# Install nvm (if not already installed)
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash

# Restart your shell, then:
nvm install   # reads .nvmrc and installs v25
nvm use       # activates v25 in the current shell
```

To activate automatically whenever you enter this directory, add this to your `~/.bashrc` or `~/.zshrc`:

```sh
autoload -U add-zsh-hook  # zsh only
nvm use --silent 2>/dev/null || true
```

Or use a shell plugin such as [zsh-nvm](https://github.com/lukechilds/zsh-nvm) that handles `.nvmrc` automatically.

## Install dependencies

```sh
corepack enable
pnpm install
pnpm exec playwright install chromium
```

## Developer setup

If you are contributing to this repo, install the same tools the CI workflows use:

- `nvm` to load the Node version pinned in `.nvmrc`
- Node.js v25 via `nvm install && nvm use`
- `corepack` with `pnpm` 10
- Python 3.12+
- `ansible-lint`
- `yamllint`
- Ansible collections from `requirements.yml`

One working setup looks like this:

```sh
# Node / pnpm
nvm install
nvm use
corepack enable
pnpm install
pnpm exec playwright install chromium

# Python / Ansible linting
python3 -m pip install --user ansible-lint yamllint
ansible-galaxy collection install -r requirements.yml
```

Before opening or updating a PR, run the same checks expected by this repository:

```sh
pnpm run lint
pnpm run prettier
yamllint .
ansible-lint
ansible-playbook --syntax-check site.yml
```

## Smoke test workflow

The smoke tests run against a real EC2 instance provisioned by Terraform and configured by Ansible. There are three separate steps so you can debug between them.

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
| `http_cidr`  | CIDR for HTTP access (use `0.0.0.0/0` for certbot, otherwise restrict) |
| `https_cidr` | CIDR for HTTPS access                                                  |

An SSH key pair is generated automatically — no pre-existing EC2 key pair is needed.

### 2. Start the server

```sh
pnpm infra:up
```

Creates the EC2 instance, generates a dedicated SSH key pair, runs the Ansible playbook, and saves connection details to `.smoke-state/state.json`.

For the configurable-port Elementary smoke path, provision with:

```sh
pnpm provision:elementary:custom-ports
```

This installs noVNC behind nginx on `8080/8443` and updates the smoke state so `pnpm test` targets those ports.
The shared provision helper also accepts `NOVNC_HTTP_PORT` / `NOVNC_HTTPS_PORT` overrides for other smoke port pairs.

### 3. Check connection details

```sh
pnpm infra:status
```

Prints the SSH command and desktop URL.

### 4. Run the tests

```sh
pnpm test
```

Runs the Playwright smoke tests against the live server.

### 5. Destroy the server

```sh
pnpm infra:down
```

Destroys the EC2 instance, security group, and key pair.

## Ansible role usage

### Install from GitHub (single requirements.yml entry)

Add this to your `requirements.yml`:

```yaml
roles:
  - name: markcallen.novnc_desktop
    src: https://github.com/markcallen/novnc-desktop
    scm: git
    version: v0.1.1

collections:
  - name: ansible.utils
    version: '>=2.0.0'
  - name: community.general
```

Then install and run:

```sh
ansible-galaxy install -r requirements.yml
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbook.yml -i <host>, -u ubuntu --private-key ~/.ssh/key.pem
```

Example playbook:

```yaml
---
- name: Provision noVNC desktop
  hosts: all
  become: true
  roles:
    - markcallen.novnc_desktop
```

### Clone and run directly

```sh
git clone https://github.com/markcallen/novnc-desktop.git
cd novnc-desktop
git checkout v0.1.1
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml -i <host>, -u ubuntu --private-key ~/.ssh/key.pem
```

Key variables:

| Variable                    | Default    | Description                                                    |
| --------------------------- | ---------- | -------------------------------------------------------------- |
| `desktop_type`              | `openbox`  | Desktop environment: `openbox`, `elementary`                   |
| `vnc_user`                  | `ubuntu`   | OS user that owns the desktop session                          |
| `vnc_geometry`              | `1280x720` | Screen resolution                                              |
| `auth_token_ttl_seconds`    | `28800`    | Token lifetime in seconds (default 8 hours)                    |
| `novnc_http_port`           | `80`       | Public HTTP port that redirects to HTTPS                       |
| `novnc_https_port`          | `443`      | Public HTTPS port served by nginx                              |
| `use_certbot`               | `false`    | Attempt Let's Encrypt certificate acquisition on `80/443` only |
| `smoke_test_marker_enabled` | `false`    | Render green xterm marker for canvas verification              |

After provisioning, SSH in and run `novnc-desktop-url` to get a signed HTTPS URL for the desktop.

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

## Pre-built AMIs

Public AMIs for openbox and elementary variants are available for each release. See the [GitHub Releases](https://github.com/markcallen/novnc-desktop/releases) page for current AMI IDs by region.

AMIs are built with `use_certbot: false` — TLS certificates are not embedded at build time. Instead, pass a user-data script at launch to obtain a Let's Encrypt certificate for your domain.

### Launch workflow

1. **Choose an AMI** from the release notes for your region and desktop variant.

2. **Prepare a user-data script** — copy `examples/user-metadata-certbot-example.sh` and set your domain and email at the top:

   ```bash
   #!/bin/bash
   export CERTBOT_DOMAIN=myapp.example.com
   export CERTBOT_EMAIL=admin@example.com
   export NOVNC_PORT=443
   export NOVNC_UNSECURED_PORT=80
   # Paste the contents of examples/user-metadata-certbot-example.sh here
   ```

3. **Launch the instance** passing your script as user data:

   ```sh
   aws ec2 run-instances \
     --image-id ami-XXXXXXXX \
     --instance-type t3.medium \
     --user-data file://user-data.sh \
     --security-group-ids sg-XXXXXXXX
   ```

   Or via the EC2 console: Advanced Details → User data → paste your script.

4. **Wait for the stack to start** (typically 2–3 minutes after launch). Check progress:

   ```sh
   ssh ubuntu@<public-ip> journalctl -u novnc-desktop -f
   ```

5. **Get your access URL**:

   ```sh
   ssh ubuntu@<public-ip> novnc-desktop-url
   ```

### Building AMIs

To build both variants yourself:

```sh
# Build private AMIs (default)
./build-ami.sh

# Build public AMIs for distribution
AMI_PUBLIC=true ./build-ami.sh

# Custom prefix and region
AMI_NAME_PREFIX=my-novnc AWS_REGION=us-west-2 AMI_PUBLIC=true ./build-ami.sh
```

| Variable          | Default                      | Description                                         |
| ----------------- | ---------------------------- | --------------------------------------------------- |
| `AWS_REGION`      | `us-east-1`                  | AWS region to build in                              |
| `INSTANCE_TYPE`   | `t3.medium`                  | EC2 instance type for the build                     |
| `AMI_NAME_PREFIX` | `novnc-desktop-ubuntu-24.04` | Prefix applied to both openbox and elementary names |
| `USE_CERTBOT`     | `false`                      | Run certbot at bake time (only for private AMIs)    |
| `AMI_PUBLIC`      | `false`                      | Make resulting AMIs publicly launchable             |

## License

MIT License - see [LICENSE](LICENSE) file for details.
