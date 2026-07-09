SHELL := /bin/bash

# ---------------------------------------------------------------------------
# Tool versions — keep in sync with .nvmrc, package.json, and smoke/ec2/versions.tf
# ---------------------------------------------------------------------------
ANSIBLE_MIN_VERSION := 2.17
NODE_VERSION        := $(shell cat .nvmrc 2>/dev/null | tr -d 'v\n')
PNPM_MIN_VERSION    := 10
TF_VERSION          := 1.14.6
PACKER_MIN_VERSION  := 1.11.0

NVM_DIR ?= $(HOME)/.nvm

.PHONY: setup setup-check setup-node setup-pnpm \
        setup-terraform setup-packer setup-deps setup-playwright setup-galaxy

.PHONY: e2e e2e-ami

E2E_VARIANTS := openbox elementary

# ---------------------------------------------------------------------------
# setup — install and configure all required tools
# ---------------------------------------------------------------------------
setup: setup-node setup-pnpm setup-terraform setup-packer \
       setup-deps setup-playwright setup-galaxy
	@echo ""
	@$(MAKE) --no-print-directory setup-check

# ---------------------------------------------------------------------------
# setup-check — print active versions for each required tool
# ---------------------------------------------------------------------------
setup-check:
	@echo "==> Tool versions"
	@printf "  %-14s %s\n" "ansible:"   "$$(ansible --version 2>/dev/null | head -1 | sed 's/ansible \[core \(.*\)\]/\1/' || echo 'not found')"
	@printf "  %-14s %s\n" "node:"      "$$(node --version 2>/dev/null || echo 'not found')"
	@printf "  %-14s %s\n" "pnpm:"      "$$(pnpm --version 2>/dev/null || echo 'not found')"
	@printf "  %-14s %s\n" "terraform:" "$$(terraform --version 2>/dev/null | head -1 | sed 's/Terraform v//' || echo 'not found')"
	@printf "  %-14s %s\n" "packer:"    "$$(packer --version 2>/dev/null | sed 's/Packer v//' || echo 'not found')"
	@printf "  %-14s %s\n" "python:"    "$$(python3 --version 2>/dev/null || echo 'not found')"
	@printf "  %-14s %s\n" "playwright:" "$$(pnpm exec playwright --version 2>/dev/null | sed 's/Version //' || echo 'not found')"

# ---------------------------------------------------------------------------
# setup-node — install Node.js via nvm using the version in .nvmrc
# ---------------------------------------------------------------------------
setup-node:
	@echo "==> Installing Node.js $(NODE_VERSION) via nvm..."
	@[[ -s "$(NVM_DIR)/nvm.sh" ]] || { echo "ERROR: nvm not found at $(NVM_DIR). Install with: brew install nvm"; exit 1; }
	source "$(NVM_DIR)/nvm.sh" && nvm install $(NODE_VERSION) && nvm use $(NODE_VERSION)
	@echo "  Active: $$(node --version 2>/dev/null || echo 'not found')"

# ---------------------------------------------------------------------------
# setup-pnpm — verify pnpm is available (managed by brew)
# ---------------------------------------------------------------------------
setup-pnpm:
	@echo "==> Checking pnpm..."
	@which pnpm >/dev/null 2>&1 || { echo "ERROR: pnpm not found. Install with: brew install pnpm"; exit 1; }
	@echo "  Active: $$(pnpm --version)"

# ---------------------------------------------------------------------------
# setup-terraform — install Terraform 1.14.6 via tfenv
# ---------------------------------------------------------------------------
setup-terraform:
	@echo "==> Installing Terraform $(TF_VERSION) via tfenv..."
	@which tfenv >/dev/null 2>&1 || { echo "ERROR: tfenv not found. Install with: brew install tfenv"; exit 1; }
	tfenv install $(TF_VERSION)
	tfenv use $(TF_VERSION)
	@echo "  Active: $$(terraform --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
# setup-packer — verify packer >= 1.11.0 is available (managed by brew)
# ---------------------------------------------------------------------------
setup-packer:
	@echo "==> Checking Packer >= $(PACKER_MIN_VERSION)..."
	@which packer >/dev/null 2>&1 || { echo "ERROR: packer not found. Install with: brew install packer"; exit 1; }
	@PACKER_VER=$$(packer --version 2>/dev/null | tr -d 'v'); \
	  MAJOR=$$(echo $$PACKER_VER | cut -d. -f1); \
	  MINOR=$$(echo $$PACKER_VER | cut -d. -f2); \
	  if (( MAJOR > 1 || (MAJOR == 1 && MINOR >= 11) )); then \
	    echo "  Active: Packer v$$PACKER_VER"; \
	  else \
	    echo "ERROR: Packer $$PACKER_VER < $(PACKER_MIN_VERSION). Upgrade with: brew upgrade packer"; \
	    exit 1; \
	  fi

# ---------------------------------------------------------------------------
# setup-deps — install Node dependencies and Playwright browsers
# ---------------------------------------------------------------------------
setup-deps:
	@echo "==> Installing Node.js dependencies..."
	pnpm install --frozen-lockfile

# ---------------------------------------------------------------------------
# setup-playwright — install Playwright browser binaries and system dependencies
# ---------------------------------------------------------------------------
setup-playwright:
	@echo "==> Installing Playwright browser binaries..."
	pnpm exec playwright install chromium
	@echo "==> Installing Playwright system dependencies (requires sudo)..."
	pnpm exec playwright install-deps chromium

# ---------------------------------------------------------------------------
# setup-galaxy — install Ansible Galaxy collections
# ---------------------------------------------------------------------------
setup-galaxy:
	@echo "==> Installing Ansible Galaxy requirements..."
	ansible-galaxy install -r requirements.yml --force

# ---------------------------------------------------------------------------
# e2e — run direct-provision smoke tests for each desktop variant
# ---------------------------------------------------------------------------
e2e:
	@set -euo pipefail; \
	needs_teardown=0; \
	cleanup() { \
	  if [[ "$$needs_teardown" == "1" ]]; then \
	    echo "==> Tearing down smoke infrastructure..."; \
	    pnpm infra:down || true; \
	    needs_teardown=0; \
	  fi; \
	}; \
	trap cleanup EXIT; \
	for variant in $(E2E_VARIANTS); do \
	  echo "==> Running direct-provision E2E smoke tests for $$variant"; \
	  needs_teardown=1; \
	  pnpm infra:up; \
	  pnpm provision:$$variant; \
	  pnpm test -- --workers=1; \
	  cleanup; \
	done

# ---------------------------------------------------------------------------
# e2e-ami — build AMIs, then launch and smoke-test each AMI variant
# ---------------------------------------------------------------------------
e2e-ami:
	@set -euo pipefail; \
	needs_teardown=0; \
	cleanup() { \
	  if [[ "$$needs_teardown" == "1" ]]; then \
	    echo "==> Tearing down AMI smoke infrastructure..."; \
	    pnpm infra:down || true; \
	    needs_teardown=0; \
	  fi; \
	}; \
	trap cleanup EXIT; \
	echo "==> Building AMIs for all desktop variants"; \
	pnpm build:ami; \
	for variant in $(E2E_VARIANTS); do \
	  echo "==> Running AMI E2E smoke tests for $$variant"; \
	  needs_teardown=1; \
	  pnpm infra:ami --variant "$$variant"; \
	  pnpm test -- --workers=1; \
	  cleanup; \
	done
