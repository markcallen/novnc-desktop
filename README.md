# novnc-desktop

[![Lint](https://github.com/markcallen/novnc-desktop/actions/workflows/lint.yml/badge.svg)](https://github.com/markcallen/novnc-desktop/actions/workflows/lint.yml)
[![Ansible Lint](https://github.com/markcallen/novnc-desktop/actions/workflows/ansible-lint.yml/badge.svg)](https://github.com/markcallen/novnc-desktop/actions/workflows/ansible-lint.yml)
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

```sh
ansible-galaxy install -r requirements.yml
ansible-playbook site.yml -i <host>, -u ubuntu --private-key ~/.ssh/key.pem
```

Key variables:

| Variable                    | Default    | Description                                       |
| --------------------------- | ---------- | ------------------------------------------------- |
| `desktop_type`              | `openbox`  | Desktop environment: `openbox`, `elementary`      |
| `vnc_user`                  | `ubuntu`   | OS user that owns the desktop session             |
| `vnc_geometry`              | `1280x720` | Screen resolution                                 |
| `auth_token_ttl_seconds`    | `28800`    | Token lifetime in seconds (default 8 hours)       |
| `use_certbot`               | `false`    | Attempt Let's Encrypt certificate acquisition     |
| `smoke_test_marker_enabled` | `false`    | Render green xterm marker for canvas verification |

After provisioning, SSH in and run `novnc-desktop-url` to get a signed HTTPS URL for the desktop.

## License

MIT License - see [LICENSE](LICENSE) file for details.
