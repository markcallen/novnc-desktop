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
3. After provisioning, the developer SSHs in and runs `novnc-desktop-url` to get a signed URL they can paste into any browser.
4. Self-signed TLS certificates work out of the box. Let's Encrypt is available as an opt-in upgrade when a public domain is configured.
5. The desktop environment is configurable: Openbox (default, lightweight), Pantheon (Elementary), or Deepin.
6. The role is usable standalone and as a component of larger automation stacks (specifically `ai-agent-desktop`, which relies on this role for its nginx access layer).
7. Multiple OS users on the same host can each have an independent desktop session. Each session is isolated by VNC display number and websockify port. Running `novnc-desktop-url` creates a desktop for the calling OS user if one does not already exist.

---

## Non-Goals

- **Display manager / login screen.** The session is started directly by TigerVNC; there is no graphical login prompt. _(Moved from Non-Goals — display manager masking is still enforced.)_
- **Windows or non-Ubuntu Linux.** Ubuntu 24.04 LTS (Noble) is the only supported target OS.
- **Managed cloud infrastructure.** The role configures software on an existing host. Provisioning VMs, DNS records, or load balancers is the caller's responsibility.
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
| FR-2.2 | All public traffic is served by Nginx over HTTPS. The public HTTP and HTTPS listen ports are configurable, and requests received on the configured HTTP port are redirected to the configured HTTPS port.   |
| FR-2.3 | Every request to the noVNC interface is gated by an Nginx `auth_request` subrequest to the `novnc-auth` service. Unauthenticated requests receive a `302` redirect to `/access`.                            |
| FR-2.4 | Access tokens are HMAC-SHA256 signed, contain an expiry timestamp, and are verified on every request. A tampered or expired token is rejected.                                                              |
| FR-2.5 | The HMAC secret is generated randomly at provisioning time and stored at `/etc/novnc-auth/secret` (mode `0600`, owned by the `novnc-auth` service user). It is never written to a playbook variable or log. |
| FR-2.6 | The token-generation endpoint (`POST /generate`) is blocked by Nginx for all external requests. It is reachable only from `127.0.0.1`.                                                                      |
| FR-2.7 | The access cookie is set `HttpOnly`, `Secure`, `SameSite=Lax`, scoped to `Path=/`, with `Max-Age` matching the token TTL.                                                                                   |

### FR-3 — `novnc-desktop-url` command

| ID     | Requirement                                                                                                                                                                       |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-3.1 | `novnc-desktop-url` is installed to `/usr/local/bin/novnc-desktop-url` and is executable by any user on the host.                                                                 |
| FR-3.2 | Running `novnc-desktop-url` prints a complete HTTPS URL and its expiry time to stdout. When `novnc_https_port` is not `443`, the generated URL includes that port by default.     |
| FR-3.3 | The URL, when opened in a browser, authenticates the session, sets the access cookie, and redirects to `vnc.html?autoconnect=1&resize=remote` without any additional user action. |
| FR-3.4 | The default token TTL is 8 hours. It is configurable via the `auth_token_ttl_seconds` variable.                                                                                   |
| FR-3.5 | If the `novnc-auth` service is not running, `novnc-desktop-url` exits with a non-zero status and a human-readable error message.                                                  |

### FR-4 — TLS certificates

| ID     | Requirement                                                                                                                                                                                                                                                         |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-4.1 | A self-signed certificate valid for 730 days is generated at provisioning time and used by default. Nginx starts successfully with this certificate.                                                                                                                |
| FR-4.2 | When `use_certbot: true` is set, `tls_domain` resolves to a publicly routable IP address, `letsencrypt_email` is configured, and `novnc_http_port`/`novnc_https_port` remain `80`/`443`, the role obtains a Let's Encrypt certificate via the Nginx certbot plugin. |
| FR-4.3 | If any condition for FR-4.2 is not met, the role falls back to the self-signed certificate without failing. The fallback reason is reported via an Ansible debug message.                                                                                           |

### FR-5 — Desktop environments

| ID     | Requirement                                                                                                                                                                                                                     |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-5.1 | **Openbox**: installs `openbox`, `tint2`, and `xterm`. Fully supported on Ubuntu 24.04 from main repos.                                                                                                                         |
| FR-5.2 | **Elementary (Pantheon)**: installs from `ppa:elementary-os/stable`. Treated as best-effort; if the PPA does not support the host's Ubuntu release the task warns and continues rather than failing the playbook.               |
| FR-5.3 | For all desktop types, any display manager pulled in as a dependency is masked so it does not conflict with TigerVNC's display ownership.                                                                                       |
| FR-5.4 | **Elementary (Pantheon)**: when `gala` crashes during VNC session startup or while the session remains active under software rendering, the session automatically restarts `gala` without requiring a TigerVNC service restart. |
| FR-5.5 | **Elementary (Pantheon)**: when `smoke_test_marker_enabled=true`, the `SMOKE_READY` xterm is raised and focused after session startup so keyboard input works immediately through noVNC.                                        |
| FR-5.6 | **Elementary (Pantheon)**: the Pantheon shell override used to suppress focus-stealing components is deployed only when `smoke_test_marker_enabled=true` so non-smoke sessions keep the default shell layout.                   |

### FR-6 — `novnc-auth` service

| ID     | Requirement                                                                                                                       |
| ------ | --------------------------------------------------------------------------------------------------------------------------------- |
| FR-6.1 | The service runs as a dedicated system user `novnc-auth` (no login shell, no home directory access).                              |
| FR-6.2 | The service is managed by systemd, starts automatically on boot, and restarts on failure.                                         |
| FR-6.3 | The service is implemented in Python 3 using only the standard library. No `pip` installation is required.                        |
| FR-6.4 | `GET /access?token=<tok>` validates the token, sets the access cookie, and redirects to `vnc.html?autoconnect=1&resize=remote`.   |
| FR-6.5 | `GET /verify` checks the access cookie. Returns `200` if valid, `401` otherwise. This endpoint is called by Nginx `auth_request`. |
| FR-6.6 | `POST /generate` mints a new token and returns `{"url": "...", "token": "...", "expires_at": "..."}`.                             |

### FR-7 — Direct Ansible provisioning on an existing EC2 instance

The "bring your own instance" path: the operator has a running Ubuntu 24.04 EC2
instance and provisions it by running `ansible-playbook site.yml` against it.
No Packer or AMI tooling is required.

| ID     | Requirement                                                                                                                                        |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-7.1 | Running `ansible-playbook site.yml -i <host>, -u ubuntu --private-key <key>` against a clean Ubuntu 24.04 EC2 instance completes without error.    |
| FR-7.2 | After provisioning, `novnc-desktop-url` is present at `/usr/local/bin/novnc-desktop-url` and executable by all users on the host.                  |
| FR-7.3 | After provisioning, `novnc-setup-tls` is present at `/usr/local/bin/novnc-setup-tls` and executable by all users on the host.                      |
| FR-7.4 | After provisioning, `novnc-auth.service`, `nginx`, `novnc.service`, and `novnc-desktop.service` are all active and enabled in systemd.             |
| FR-7.5 | The provisioning smoke flow (`pnpm infra:up && pnpm provision:<variant> && pnpm test`) completes with all Acceptance Criteria passing.             |
| FR-7.6 | After provisioning, `novnc-set-base-url` is present at `/usr/local/bin/novnc-set-base-url` and `novnc-set-base-url.service` is enabled in systemd. |

### FR-8 — AMI build and launch

The "pre-built image" path: Packer bakes an AMI with all Ansible roles applied.
An EC2 instance launched from that AMI has the full desktop stack present on
first boot. Post-launch setup is limited to TLS configuration (via
`novnc-setup-tls` or user-data); no full Ansible re-run is required.

| ID      | Requirement                                                                                                                                                                                                                                                                                                                        |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-8.1  | `build-ami.sh` produces one AMI per supported desktop variant (`openbox`, `elementary`) tagged with `Variant`, `Environment`, `Project=novnc-desktop`, and `BuildDate`.                                                                                                                                                            |
| FR-8.2  | `packer-playbook.yml` runs all five Ansible roles (`desktop`, `vnc`, `novnc`, `auth`, `nginx`) during the Packer build so the AMI is fully provisioned.                                                                                                                                                                            |
| FR-8.3  | An EC2 instance launched from the AMI has `novnc-desktop-url` present at `/usr/local/bin/novnc-desktop-url` without any post-launch Ansible run.                                                                                                                                                                                   |
| FR-8.4  | An EC2 instance launched from the AMI has `novnc-setup-tls` present at `/usr/local/bin/novnc-setup-tls` without any post-launch Ansible run.                                                                                                                                                                                       |
| FR-8.5  | `novnc-auth.service`, `nginx`, `novnc.service`, and `novnc-desktop.service` are active and enabled on an instance launched from the AMI without any post-launch Ansible run.                                                                                                                                                       |
| FR-8.6  | After running `novnc-setup-tls` (or equivalent user-data) on an AMI-launched instance, the desktop is accessible via HTTPS and `novnc-desktop-url` returns a valid URL identical to an Ansible-provisioned host.                                                                                                                   |
| FR-8.7  | The AMI smoke flow (`pnpm infra:ami:<variant> && pnpm provision:<variant> && pnpm test`) completes with all Acceptance Criteria passing.                                                                                                                                                                                           |
| FR-8.8  | An EC2 instance launched from the AMI has `novnc-set-base-url` present at `/usr/local/bin/novnc-set-base-url` and `novnc-set-base-url.service` enabled, without any post-launch Ansible run.                                                                                                                                       |
| FR-8.9  | On every boot of an AMI-launched instance, `novnc-set-base-url.service` queries EC2 instance metadata and writes the instance's public hostname (or public IPv4 fallback) as the `novnc-auth` base URL, so that `novnc-desktop-url` returns a URL containing the actual public address — not the build-time placeholder `default`. |
| FR-8.10 | When a Let's Encrypt certificate is present (i.e. `novnc-setup-tls` has been run), `novnc-set-base-url.service` skips the metadata update on reboot so that the domain-based URL configured by `novnc-setup-tls` is preserved.                                                                                                     |

### FR-9 — Multi-user desktop sessions

Multiple OS users on the same host may each run an independent desktop session. Each session is isolated: a distinct VNC display (`:N`) and a dedicated websockify port (`6080 + N`). nginx routes each authenticated browser session to the correct websockify backend based on user identity embedded in the signed access token.

| ID     | Requirement                                                                                                                                                                                          |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FR-9.1 | The auth service maintains a user registry at `/etc/novnc-auth/users.json` that maps each OS username to its assigned display number and websockify port.                                            |
| FR-9.2 | Access tokens embed the username and websockify port in the signed payload. A tampered port is rejected along with a tampered expiry.                                                                |
| FR-9.3 | `GET /verify` returns an `X-VNC-Backend` response header containing `127.0.0.1:<ws_port>` for the authenticated user. nginx uses this header to route the request to the correct websockify process. |
| FR-9.4 | `POST /generate?user=<name>` (localhost only) mints a token scoped to the named OS user. If the user is not registered, the endpoint returns a `404` JSON error.                                     |
| FR-9.5 | `POST /register` (localhost only) accepts `{"user": "<name>", "display": N, "ws_port": M}` and adds or updates the user in the registry. Returns the stored entry.                                   |
| FR-9.6 | `GET /user-status?user=<name>` (localhost only) returns the user's registry entry or a `404` JSON error if the user is not registered.                                                               |
| FR-9.7 | The provisioning playbook pre-registers the configured `auth_initial_user` (default: `ubuntu`) in the user registry so the single-user workflow continues to work without any additional setup.      |
| FR-9.8 | `novnc-desktop-url` passes the calling OS user (`id -un`) to `/generate`. If the user is not registered, it exits with a non-zero status and a human-readable message explaining the next step.      |
| FR-9.9 | nginx uses `auth_request_set` to capture the `X-VNC-Backend` header from `/verify` and applies it as the `proxy_pass` target, routing each session to its user-specific websockify port.             |

---

## Non-Functional Requirements

| ID    | Requirement                                                                                                                                                            |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| NFR-1 | **Idempotency.** The playbook can be run multiple times without disrupting an active desktop session or regenerating the HMAC secret.                                  |
| NFR-2 | **Minimal footprint.** The role installs only what is needed. It does not install Node.js, Docker, or any runtime not already implied by the selected desktop type.    |
| NFR-3 | **No external API calls at access time.** Token validation is purely local (HMAC verification + timestamp check). The `novnc-auth` service makes no outbound requests. |
| NFR-4 | **Composability.** The role exposes clean variable interfaces so it can be imported and overridden by a parent playbook (e.g. `ai-agent-desktop`) without forking.     |
| NFR-5 | **Firewall by default.** UFW is enabled at the end of provisioning. Only SSH (22) and the configured public noVNC HTTP/HTTPS ports are permitted inbound.              |

---

## Acceptance Criteria

Each AC maps to one or more Functional Requirements and is covered by a named
smoke test. After running `pnpm test`, `.smoke-artifacts/verification.json`
records whether each criterion passed for the specific AMI and commit under
test. Agents and operators should read that file to confirm the system is
verified rather than re-running the full suite.

To find the test that covers an AC, search the codebase for the AC ID string
(e.g. `grep -r "AC-TLS-01" smoke/`).

### TLS and network

| ID        | Requirement covered | Observable outcome                                                        |
| --------- | ------------------- | ------------------------------------------------------------------------- |
| AC-TLS-01 | FR-4.1              | HTTPS endpoint responds (status < 500)                                    |
| AC-TLS-02 | FR-2.2              | HTTP request receives a `301` redirect to the HTTPS URL                   |
| AC-TLS-03 | FR-3.2              | Access URL returned by `novnc-desktop-url` uses the configured HTTPS port |

### Authentication and access control

| ID         | Requirement covered | Observable outcome                                                       |
| ---------- | ------------------- | ------------------------------------------------------------------------ |
| AC-AUTH-01 | FR-2.3              | Unauthenticated `GET /` returns `302` to `/access`                       |
| AC-AUTH-02 | FR-2.6              | `POST /generate` from an external address returns `403`                  |
| AC-AUTH-03 | FR-3.3              | Visiting the access URL sets the auth cookie and redirects to `vnc.html` |

### Desktop rendering

| ID            | Requirement covered | Observable outcome                                            |
| ------------- | ------------------- | ------------------------------------------------------------- |
| AC-DESKTOP-01 | FR-5.1, FR-5.2      | VNC canvas renders the desktop; smoke marker xterm is visible |

### Elementary (Pantheon) — verified only when `desktopType=elementary`

| ID               | Requirement covered | Observable outcome                                        |
| ---------------- | ------------------- | --------------------------------------------------------- |
| AC-ELEMENTARY-01 | FR-5.4              | `gala` process restarts within 20 s after being killed    |
| AC-ELEMENTARY-02 | FR-5.5              | Clicking the noVNC canvas focuses the `SMOKE_READY` xterm |

### Direct Ansible provisioning — verified by `pnpm infra:up + provision:* + test`

These criteria confirm the state of a host that was provisioned from scratch
using `ansible-playbook site.yml`. They are satisfied when the commands and
services required by FR-7 are present and running after the Ansible run
completes.

| ID            | Requirement covered | Observable outcome                                                                         |
| ------------- | ------------------- | ------------------------------------------------------------------------------------------ |
| AC-ANSIBLE-01 | FR-7.2              | `novnc-desktop-url` is present at `/usr/local/bin/novnc-desktop-url` and executable        |
| AC-ANSIBLE-02 | FR-7.3              | `novnc-setup-tls` is present at `/usr/local/bin/novnc-setup-tls` and executable            |
| AC-ANSIBLE-03 | FR-7.4              | `novnc-auth.service`, `nginx`, `novnc.service`, and `novnc-desktop.service` are all active |
| AC-ANSIBLE-04 | FR-7.6              | `novnc-set-base-url` is present at `/usr/local/bin/novnc-set-base-url` and executable      |
| AC-ANSIBLE-05 | FR-7.6              | `novnc-set-base-url.service` is enabled in systemd                                         |

### AMI build and launch — verified by `pnpm infra:ami:* + provision:* + test`

These criteria confirm the state of a host launched from a pre-built AMI.
AC-AMI-01 is verified at build time by `build-ami.sh`. AC-AMI-02 through
AC-AMI-04 are verified in two stages: first by an immediate SSH check in
`infra-ami.sh` right after the instance becomes reachable (confirming the AMI
baked the content in), and again by the full smoke suite.

| ID        | Requirement covered | Observable outcome                                                                                                                             | Verified by                            |
| --------- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| AC-AMI-01 | FR-8.1              | AMI tagged with `Variant`, `Environment`, `Project=novnc-desktop`, and `BuildDate`                                                             | `build-ami.sh` output + AWS console    |
| AC-AMI-02 | FR-8.3              | `novnc-desktop-url` present on AMI-launched instance before any Ansible post-launch run                                                        | `infra-ami.sh` SSH check + smoke suite |
| AC-AMI-03 | FR-8.4              | `novnc-setup-tls` present on AMI-launched instance before any Ansible post-launch run                                                          | `infra-ami.sh` SSH check + smoke suite |
| AC-AMI-04 | FR-8.5              | All required services active on AMI-launched instance before any Ansible post-launch run                                                       | `infra-ami.sh` SSH check + smoke suite |
| AC-AMI-05 | FR-8.8              | `novnc-set-base-url` present at `/usr/local/bin/novnc-set-base-url` and executable on AMI-launched instance before any Ansible post-launch run | `infra-ami.sh` SSH check + smoke suite |
| AC-AMI-06 | FR-8.8              | `novnc-set-base-url.service` is enabled and active on an AMI-launched instance                                                                 | `infra-ami.sh` SSH check + smoke suite |
| AC-AMI-07 | FR-8.9              | After boot, the URL returned by `novnc-desktop-url` contains the instance's public IP or hostname — not the build-time placeholder `default`   | smoke suite                            |

---

## Architecture

```
Browser
  │  HTTPS {{ novnc_https_port }}
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
  └── novnc-desktop-url  ──► curl POST http://127.0.0.1:8898/generate
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
| Firewall        | UFW                             | SSH + configured public noVNC ports  |

---

## Configuration Reference

| Variable                    | Default                                               | Description                                                                                |
| --------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `desktop_type`              | `openbox`                                             | Desktop environment: `openbox`, `elementary`                                               |
| `vnc_user`                  | `ubuntu`                                              | OS user that owns the desktop session                                                      |
| `vnc_display`               | `1`                                                   | X display number                                                                           |
| `vnc_geometry`              | `1280x720`                                            | Screen resolution                                                                          |
| `vnc_depth`                 | `24`                                                  | Colour depth                                                                               |
| `auth_token_ttl_seconds`    | `28800`                                               | Token lifetime (8 hours)                                                                   |
| `novnc_http_port`           | `80`                                                  | Public HTTP port that redirects to HTTPS                                                   |
| `novnc_https_port`          | `443`                                                 | Public HTTPS port served by Nginx                                                          |
| `novnc_base_url`            | `https://{{ inventory_hostname }}[:novnc_https_port]` | Base URL embedded in generated access URLs; includes the HTTPS port when it is non-default |
| `auth_service_port`         | `8898`                                                | Port the `novnc-auth` service listens on (localhost only)                                  |
| `use_certbot`               | `false`                                               | Attempt Let's Encrypt certificate acquisition on standard ports `80/443` only              |
| `tls_domain`                | `{{ inventory_hostname }}`                            | Domain for the TLS certificate                                                             |
| `letsencrypt_email`         | `""`                                                  | Email for Let's Encrypt registration                                                       |
| `smoke_test_marker_enabled` | `false`                                               | Renders a bright-green xterm for smoke test canvas verification                            |

---

## Delivery Roadmap

### Phase 1 — Foundation (current)

- [x] Role structure: `desktop`, `vnc`, `novnc`, `auth`, `nginx`
- [x] Openbox desktop (default)
- [x] TigerVNC with `SecurityTypes=None`
- [x] `novnc-auth` Python service (HMAC-SHA256 tokens, stdlib only)
- [x] Nginx `auth_request` integration
- [x] `novnc-desktop-url` CLI command
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

- [ ] Token rotation: `novnc-desktop-url --renew` invalidates prior cookie and issues a fresh token
- [ ] Configurable session idle timeout (nginx `proxy_read_timeout` + auth TTL alignment)
- [ ] Health check endpoint (`GET /health`) on `novnc-auth` for monitoring
- [ ] Ansible Galaxy publication as a standalone role (`markcallen.novnc_desktop`)
- [x] `novnc_base_url` auto-detection from public IP when not explicitly set (`novnc-set-base-url.service` runs on every boot, skips when Let's Encrypt cert is present)

### Phase 4 — `ai-agent-desktop` integration

- [ ] Expose `novnc-auth` token generation via a documented API contract for parent playbooks
- [ ] Provide an include-vars interface so `ai-agent-desktop` can override `novnc_base_url`, TTL, and service port without patching the role
- [ ] Integration smoke test: `ai-agent-desktop` playbook imports `novnc-desktop` role and mints a token through it
