# AGENTS.md

This file provides shared repository guidance for agent tools that read AGENTS.md.

## Repository Facts

Use this section for durable repo-specific facts that agents repeatedly need. Prefer facts stored here over re-deriving them with shell commands on every task.

Keep only stable, reviewable metadata here. Do not store secrets, credentials, or ephemeral runtime state.

- Canonical GitHub repo: `markcallen/novnc-desktop`
- Default branch: `main`
- Primary package manager: `pnpm` (v10, see `packageManager` in `package.json`)
- Version-file locations: `.nvmrc` (Node v25), `package.json` (`packageManager`)
- Canonical config files: `ansible.cfg`, `playwright.config.ts`, `eslint.config.mjs`, `.prettierrc`, `.ansible-lint`, `.yamllint`
- Primary CI workflows: `.github/workflows/lint.yml`, `.github/workflows/ansible-lint.yml`
- Primary release/publish workflows: none (private project)
- Preferred commands: `pnpm run lint`, `pnpm run prettier`, `pnpm test`, `ansible-lint`, `yamllint .`
- Coverage threshold: N/A (smoke/E2E tests only, no unit test coverage gate)
- Generated/protected paths (do not edit): `.smoke-state/`, `.smoke-artifacts/`, `.smoke-keys/`, `pnpm-lock.yaml`, `node_modules/`

Update this section when those facts change. If live runtime state is required, discover it separately instead of treating it as a durable repo fact.

## Verification Chain

This repository uses a three-level chain so agents can answer "is requirement X
verified?" without re-running the full test suite.

### Level 1 — Requirements (`PRD.md`)

`PRD.md` contains an **Acceptance Criteria** section. Each criterion has a
stable ID (`AC-TLS-01`, `AC-AUTH-03`, etc.) and states the observable outcome
that constitutes "working." Requirements are grouped under TLS, Auth, Desktop,
and Elementary.

### Level 2 — Tests (`smoke/tests/`)

Each Playwright test pushes one or more requirement annotations inside its body:

```typescript
test.info().annotations.push({ type: 'requirement', description: 'AC-TLS-01' });
```

To find which test covers a given AC, search the codebase:

```bash
grep -r "AC-TLS-01" smoke/
```

### Level 3 — Evidence (`.smoke-artifacts/verification.json`)

After every `pnpm test` run, `smoke/verification-reporter.ts` (a custom
Playwright reporter) writes `.smoke-artifacts/verification.json`. This file is
the ground truth for whether the provisioned system is verified.

**Example manifest:**

```json
{
  "timestamp": "2026-05-19T17:00:00Z",
  "commit": "d75c566",
  "ami_id": "ami-0abc1234",
  "variant": "elementary",
  "overall": "pass",
  "criteria": {
    "AC-TLS-01": {
      "status": "pass",
      "test": "nginx > HTTPS endpoint responds",
      "file": "smoke/tests/nginx.spec.ts"
    },
    "AC-TLS-02": {
      "status": "pass",
      "test": "nginx > HTTP redirects to HTTPS with 301",
      "file": "smoke/tests/nginx.spec.ts"
    },
    "AC-AUTH-03": {
      "status": "pass",
      "test": "desktop > access URL exchanges token for cookie and redirects to vnc.html",
      "file": "smoke/tests/desktop.spec.ts"
    }
  }
}
```

**How to read `overall`:**

- `"pass"` — all criteria that ran passed; the system is verified for this AMI
  and commit.
- `"fail"` — at least one criterion failed; the system is **not** verified.
- A criterion with `"status": "skip"` was conditionally skipped (e.g.
  elementary-only tests on an openbox host); this does not affect `overall`.

### Workflow for agents

1. Read `PRD.md` → understand what each AC requires.
2. Read `.smoke-artifacts/verification.json` → check `overall` and per-criterion
   status for the current AMI and commit.
3. If `verification.json` does not exist or is stale (commit mismatch), the
   system has not been verified; run the smoke suite:
   ```bash
   pnpm infra:up          # or infra:ami for an existing AMI
   pnpm provision:elementary   # or appropriate variant
   pnpm test
   ```
4. If a criterion fails, grep for its ID in `smoke/tests/` to find the test,
   then read the test to understand what observable behavior is broken.

### What the verification chain does NOT cover

- AMI build correctness (packer) — a green `verification.json` implies the
  AMI was built correctly (services are running), but does not confirm which
  Packer run produced it.
- Idempotency (NFR-1) — not tested by the smoke suite; re-run the Ansible
  playbook manually to verify.
- Let's Encrypt certificate acquisition (FR-4.2) — requires a real domain;
  smoke tests use self-signed certs only.

---

## Installed agent rules

Created by Ballast. Do not edit this section.

Read and follow these rule files in `.codex/rules/` when they apply:

- `.codex/rules/common/publishing-libraries.md` — Rules for common/publishing-libraries
- `.codex/rules/common/publishing-sdks.md` — Rules for common/publishing-sdks
- `.codex/rules/common/publishing-apps.md` — Rules for common/publishing-apps

## Installed skills

Created by Ballast. Do not edit this section.

Read and use these skill files in `.codex/rules/` when they are relevant:

- `.codex/rules/github-health-check.md` — run a comprehensive GitHub repository health check covering CI status, code quality, branch hygiene, and repo configuration
