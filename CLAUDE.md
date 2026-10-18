# CLAUDE.md

This file provides guidance to Claude Code for working in this repository.

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

## Installed agent rules

Created by Ballast. Do not edit this section.

### Repository Tool Policy

- Check `.rulesrc.json` `tools` before adding, installing, or running language tooling.
- Configured tools: ansible=ansible-lint,molecule; terraform=tfenv,tflint,trivy; typescript=pnpm,corepack.
- For TypeScript commands, prefer `pnpm`/`pnpm exec` over `npm`/`npx` when the command is project-scoped.

Read and follow these rule files in `.claude/rules/` when they apply:

- `.claude/rules/common/local-dev-autonomy.md` — Rules for common/local-dev-autonomy
- `.claude/rules/common/local-dev-badges.md` — Rules for common/local-dev-badges
- `.claude/rules/common/local-dev-env.md` — Rules for common/local-dev-env
- `.claude/rules/common/local-dev-license.md` — Rules for common/local-dev-license
- `.claude/rules/common/docs.md` — Rules for common/docs
- `.claude/rules/common/cicd.md` — Rules for common/cicd
- `.claude/rules/common/git-hooks.md` — Rules for common/git-hooks
- `.claude/rules/typescript/typescript-linting.md` — Rules for typescript/linting
- `.claude/rules/typescript/typescript-testing.md` — Rules for typescript/testing
- `.claude/rules/ansible/ansible-linting.md` — Rules for ansible/linting
- `.claude/rules/ansible/ansible-testing.md` — Rules for ansible/testing
- `.claude/rules/terraform/terraform-linting.md` — Rules for terraform/linting
- `.claude/rules/terraform/terraform-testing.md` — Rules for terraform/testing

## Installed skills

Created by Ballast. Do not edit this section.

These skills are registered with Claude Code. Invoke one by name (for example `/ballast-audit`) when it is relevant:

- `/github-health-check` — run a comprehensive GitHub repository health check covering CI status, code quality, branch hygiene, and repo configuration
- `/ballast-audit` — audit a Ballast installation for stale, unowned, oversized, and irrelevant rules and skills, and report the narrowest config that still covers the repository
