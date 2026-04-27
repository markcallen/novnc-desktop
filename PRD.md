# Product Requirements Document — novnc-desktop

## Overview

`novnc-desktop` is an Ansible role that provisions a secure, browser-accessible Linux desktop on any Ubuntu 24.04 LTS host. A developer SSHs into the machine, runs a single command to obtain a time-limited HTTPS URL, and opens a full desktop session in their browser — no VNC client, no password prompt, no port forwarding required.

---

## Problem

Developers frequently need access to a remote Linux desktop: to run GUI applications, test software in a real OS environment, or provide a consistent workspace accessible from any device. The conventional solutions all have friction:

- **VNC clients** require installing and configuring desktop software on every machine the developer works from.
- **VNC-over-SSH tunnels** are difficult to set up and brittle to maintain.
- **Cloud provider "virtual desktop" products** (AWS WorkSpaces, etc.) are expensive, opinionated, and lock the user into a specific provider.
- **Raw noVNC installs** ship with no access control beyond an optional plaintext VNC password, making public exposure unsafe.

There is no lightweight, self-hosted, provider-agnostic solution that gives a developer a browser-accessible desktop with genuine security and minimal operational overhead.

---

## Goals

1. A developer can provision a secure remote desktop on any Ubuntu 24.04 host by running a single Ansible playbook.
2. Access is token-secured over HTTPS. No VNC password is used. No VNC client is needed.
3. After provisioning, the developer SSHs in and runs `desktop-url` to get a signed URL they can paste into any browser.
4. Self-signed TLS certificates work out of the box. Let's Encrypt is available as an opt-in upgrade when a public domain is configured.
5. The desktop environment is configurable: Openbox (default, lightweight), Pantheon (Elementary), or Deepin.
6. The role is usable standalone and as a component of larger automation stacks (specifically `ai-agent-desktop`, which relies on this role for its nginx access layer).

---

## Non-Goals

- **Multi-user support.** One desktop session per host. Multiple concurrent users on one machine are out of scope.
- **Windows or non-Ubuntu Linux.** Ubuntu 24.04 LTS (Noble) is the only supported target OS.
- **Managed cloud infrastructure.** The role configures software on an existing host. Provisioning VMs, DNS records, or load balancers is the caller's responsibility.
- **Display manager / login screen.** The session is started directly by TigerVNC; there is no graphical login prompt.
- **Persistent desktop state across reprovisioning.** User home directories are preserved; the role does not manage backups or snapshots.

---

## Users

**Primary user: the developer provisioning and using the desktop.**

They are comfortable running Ansible and SSH. They may be working from a laptop, a cloud shell, or another VM. They want to open a desktop in a browser tab and get to work — the security mechanism should be invisible once the URL is in hand.

**Secondary user: an automation system (e.g. `ai-agent-desktop`).**

The role's token-auth service exposes a localhost `POST /generate` endpoint. Automation systems call this endpoint to mint access URLs programmatically, without human SSH interaction.

---

## Functional Requirements

### FR-1 — Provisioning

| ID     | Requirement                                                                                                                           |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| FR-1.1 | Running `ansible-playbook site.yml` on a clean Ubuntu 24.04 host completes without error and leaves the desktop reachable over HTTPS. |
| FR-1.2 | The playbook is idempotent. Re-running it on an already-provisioned host makes no disruptive changes.                                 |
| FR-1.3 | The `desktop_type` variable selects the desktop environment. Accepted values: `openbox` (default), `elementary`.                      |
| FR-1.4 | An unsupported `desktop_type` value causes the playbook to fail with a clear error message before making any changes.                 |

### FR-2 — Access security

| ID     | Requirement                                                                                                                                                                                                 |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-2.1 | TigerVNC binds to `127.0.0.1` only and is configured with `SecurityTypes=None`. VNC is not directly reachable from outside the host.                                                                        |
| FR-2.2 | All public traffic is served by Nginx over HTTPS. HTTP requests are redirected to HTTPS.                                                                                                                    |
| FR-2.3 | Every request to the noVNC interface is gated by an Nginx `auth_request` subrequest to the `novnc-auth` service. Unauthenticated requests receive a `302` redirect to `/access`.                            |
| FR-2.4 | Access tokens are HMAC-SHA256 signed, contain an expiry timestamp, and are verified on every request. A tampered or expired token is rejected.                                                              |
| FR-2.5 | The HMAC secret is generated randomly at provisioning time and stored at `/etc/novnc-auth/secret` (mode `0600`, owned by the `novnc-auth` service user). It is never written to a playbook variable or log. |
| FR-2.6 | The token-generation endpoint (`POST /generate`) is blocked by Nginx for all external requests. It is reachable only from `127.0.0.1`.                                                                      |
| FR-2.7 | The access cookie is set `HttpOnly`, `Secure`, `SameSite=Lax`, scoped to `Path=/`, with `Max-Age` matching the token TTL.                                                                                   |

### FR-3 — `desktop-url` command

| ID     | Requirement                                                                                                                                                                       |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-3.1 | `desktop-url` is installed to `/usr/local/bin/desktop-url` and is executable by any user on the host.                                                                             |
| FR-3.2 | Running `desktop-url` prints a complete HTTPS URL and its expiry time to stdout.                                                                                                  |
| FR-3.3 | The URL, when opened in a browser, authenticates the session, sets the access cookie, and redirects to `vnc.html?autoconnect=1&resize=remote` without any additional user action. |
| FR-3.4 | The default token TTL is 8 hours. It is configurable via the `auth_token_ttl_seconds` variable.                                                                                   |
| FR-3.5 | If the `novnc-auth` service is not running, `desktop-url` exits with a non-zero status and a human-readable error message.                                                        |

### FR-4 — TLS certificates

| ID     | Requirement                                                                                                                                                                                                 |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-4.1 | A self-signed certificate valid for 730 days is generated at provisioning time and used by default. Nginx starts successfully with this certificate.                                                        |
| FR-4.2 | When `use_certbot: true` is set, `tls_domain` resolves to a publicly routable IP address, and `letsencrypt_email` is configured, the role obtains a Let's Encrypt certificate via the Nginx certbot plugin. |
| FR-4.3 | If any condition for FR-4.2 is not met, the role falls back to the self-signed certificate without failing. The fallback reason is reported via an Ansible debug message.                                   |

### FR-5 — Desktop environments

| ID     | Requirement                                                                                                                                                                                                       |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-5.1 | **Openbox**: installs `openbox`, `tint2`, and `xterm`. Fully supported on Ubuntu 24.04 from main repos.                                                                                                           |
| FR-5.2 | **Elementary (Pantheon)**: installs from `ppa:elementary-os/stable`. Treated as best-effort; if the PPA does not support the host's Ubuntu release the task warns and continues rather than failing the playbook. |
| FR-5.3 | For all desktop types, any display manager pulled in as a dependency is masked so it does not conflict with TigerVNC's display ownership.                                                                         |

### FR-6 — `novnc-auth` service

| ID     | Requirement                                                                                                                       |
| ------ | --------------------------------------------------------------------------------------------------------------------------------- |
| FR-6.1 | The service runs as a dedicated system user `novnc-auth` (no login shell, no home directory access).                              |
| FR-6.2 | The service is managed by systemd, starts automatically on boot, and restarts on failure.                                         |
| FR-6.3 | The service is implemented in Python 3 using only the standard library. No `pip` installation is required.                        |
| FR-6.4 | `GET /access?token=<tok>` validates the token, sets the access cookie, and redirects to `vnc.html?autoconnect=1&resize=remote`.   |
| FR-6.5 | `GET /verify` checks the access cookie. Returns `200` if valid, `401` otherwise. This endpoint is called by Nginx `auth_request`. |
| FR-6.6 | `POST /generate` mints a new token and returns `{"url": "...", "token": "...", "expires_at": "..."}`.                             |

---

## Non-Functional Requirements

| ID    | Requirement                                                                                                                                                            |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| NFR-1 | **Idempotency.** The playbook can be run multiple times without disrupting an active desktop session or regenerating the HMAC secret.                                  |
| NFR-2 | **Minimal footprint.** The role installs only what is needed. It does not install Node.js, Docker, or any runtime not already implied by the selected desktop type.    |
| NFR-3 | **No external API calls at access time.** Token validation is purely local (HMAC verification + timestamp check). The `novnc-auth` service makes no outbound requests. |
| NFR-4 | **Composability.** The role exposes clean variable interfaces so it can be imported and overridden by a parent playbook (e.g. `ai-agent-desktop`) without forking.     |
| NFR-5 | **Firewall by default.** UFW is enabled at the end of provisioning. Only SSH (22) and Nginx Full (80, 443) are permitted inbound.                                      |

---

## Architecture

```
Browser
  │  HTTPS 443
  ▼
Nginx
  ├── GET /access?token=...  ──────────────────► novnc-auth :8898
  │                                               (set cookie, redirect)
  │
  ├── ALL other paths
  │     auth_request → /_auth/verify ──────────► novnc-auth :8898
  │                                               (check cookie → 200/401)
  │     proxy_pass → noVNC :6080
  │                      │
  │                      │  WebSocket
  │                      ▼
  │                 websockify :6080
  │                      │  VNC (localhost only)
  │                      ▼
  │                 TigerVNC :5901
  │                      │  X display :1
  │                      ▼
  │                 Desktop session (openbox / pantheon)
  │
  └── POST /generate  blocked (deny all)

SSH user
  └── desktop-url  ──► curl POST http://127.0.0.1:8898/generate
                        returns { url, expires_at }
```

### Key components

| Component       | Technology                      | Notes                                |
| --------------- | ------------------------------- | ------------------------------------ |
| Desktop session | TigerVNC + xstartup             | `SecurityTypes=None`; localhost-only |
| WebSocket proxy | websockify + noVNC              | systemd service; localhost-only      |
| Auth service    | Python 3 stdlib                 | `novnc-auth.py`; HMAC-SHA256 tokens  |
| Reverse proxy   | Nginx                           | TLS termination + `auth_request`     |
| TLS             | openssl (self-signed) / certbot | self-signed by default               |
| Firewall        | UFW                             | SSH + Nginx Full only                |

---

## Configuration Reference

| Variable                    | Default                            | Description                                                     |
| --------------------------- | ---------------------------------- | --------------------------------------------------------------- |
| `desktop_type`              | `openbox`                          | Desktop environment: `openbox`, `elementary`                    |
| `vnc_user`                  | `ubuntu`                           | OS user that owns the desktop session                           |
| `vnc_display`               | `1`                                | X display number                                                |
| `vnc_geometry`              | `1280x720`                         | Screen resolution                                               |
| `vnc_depth`                 | `24`                               | Colour depth                                                    |
| `default_browser`           | `firefox`                          | Browser installed alongside the desktop: `firefox`, `chrome`    |
| `auth_token_ttl_seconds`    | `28800`                            | Token lifetime (8 hours)                                        |
| `novnc_base_url`            | `https://{{ inventory_hostname }}` | Base URL embedded in generated access URLs                      |
| `auth_service_port`         | `8898`                             | Port the `novnc-auth` service listens on (localhost only)       |
| `use_certbot`               | `false`                            | Attempt Let's Encrypt certificate acquisition                   |
| `tls_domain`                | `{{ inventory_hostname }}`         | Domain for the TLS certificate                                  |
| `letsencrypt_email`         | `""`                               | Email for Let's Encrypt registration                            |
| `smoke_test_marker_enabled` | `false`                            | Renders a bright-green xterm for smoke test canvas verification |

---

## Delivery Roadmap

### Phase 1 — Foundation (current)

- [x] Role structure: `desktop`, `vnc`, `novnc`, `auth`, `nginx`
- [x] Openbox desktop (default)
- [x] TigerVNC with `SecurityTypes=None`
- [x] `novnc-auth` Python service (HMAC-SHA256 tokens, stdlib only)
- [x] Nginx `auth_request` integration
- [x] `desktop-url` CLI command
- [x] Self-signed TLS certificate generation
- [x] Let's Encrypt opt-in via certbot
- [x] UFW firewall configuration
- [x] Playwright smoke test (token-based, no VNC password)
- [x] EC2 Terraform for smoke test infrastructure

### Phase 2 — Desktop coverage and CI

- [ ] Validate Elementary (Pantheon) on Ubuntu 24.04; document PPA status
- [ ] Validate Deepin on Ubuntu 24.04; document universe package status
- [ ] GitHub Actions CI workflow: lint (`ansible-lint`) + smoke test on EC2
- [ ] `package.json` / `node_modules` smoke runner setup (Playwright install)

### Phase 3 — Hardening and developer experience

- [ ] Token rotation: `desktop-url --renew` invalidates prior cookie and issues a fresh token
- [ ] Configurable session idle timeout (nginx `proxy_read_timeout` + auth TTL alignment)
- [ ] Health check endpoint (`GET /health`) on `novnc-auth` for monitoring
- [ ] Ansible Galaxy publication as a standalone role (`markcallen.novnc_desktop`)
- [ ] `novnc_base_url` auto-detection from public IP when not explicitly set

### Phase 4 — `ai-agent-desktop` integration

- [ ] Expose `novnc-auth` token generation via a documented API contract for parent playbooks
- [ ] Provide an include-vars interface so `ai-agent-desktop` can override `novnc_base_url`, TTL, and service port without patching the role
- [ ] Integration smoke test: `ai-agent-desktop` playbook imports `novnc-desktop` role and mints a token through it
