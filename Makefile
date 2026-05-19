SHELL := /bin/bash

# ---------------------------------------------------------------------------
# Tool versions — keep in sync with .nvmrc, package.json, and smoke/ec2/versions.tf
# ---------------------------------------------------------------------------
ANSIBLE_MIN_VERSION := 2.18.0
NODE_VERSION        := $(shell cat .nvmrc 2>/dev/null | tr -d 'v\n')
PNPM_MIN_VERSION    := 10
TF_VERSION          := 1.14.6
PACKER_MIN_VERSION  := 1.11.0

NVM_DIR ?= $(HOME)/.nvm

.PHONY: setup setup-check setup-ansible setup-node setup-pnpm \
        setup-terraform setup-packer setup-deps setup-galaxy

# ---------------------------------------------------------------------------
# setup — install and configure all required tools
# ---------------------------------------------------------------------------
setup: setup-ansible setup-node setup-pnpm setup-terraform setup-packer \
       setup-deps setup-galaxy
	@echo ""
	@$(MAKE) --no-print-directory setup-check

# ---------------------------------------------------------------------------
# setup-check — print active versions for each required tool
# ---------------------------------------------------------------------------
setup-check:
	@echo "==> Tool versions"
	@printf "  %-14s %s\n" "ansible:"   "$$(~/.local/bin/ansible --version 2>/dev/null | head -1 || ansible --version 2>/dev/null | head -1 || echo 'not found')"
	@printf "  %-14s %s\n" "node:"      "$$(node --version 2>/dev/null || echo 'not found')"
	@printf "  %-14s %s\n" "pnpm:"      "$$(pnpm --version 2>/dev/null || echo 'not found')"
	@printf "  %-14s %s\n" "terraform:" "$$(terraform --version 2>/dev/null | head -1 || echo 'not found')"
	@printf "  %-14s %s\n" "packer:"    "$$(packer --version 2>/dev/null || echo 'not found')"
	@printf "  %-14s %s\n" "python:"    "$$(~/.local/share/pipx/venvs/ansible-core/bin/python --version 2>/dev/null || echo 'not found')"

# ---------------------------------------------------------------------------
# setup-ansible — install ansible-core >= 2.18 via pipx (requires Python 3.11+)
# ---------------------------------------------------------------------------
setup-ansible:
	@echo "==> Installing ansible-core >= $(ANSIBLE_MIN_VERSION) via pipx..."
	@which pipx >/dev/null 2>&1 || { echo "ERROR: pipx not found. Install with: brew install pipx"; exit 1; }
	@if ~/.local/bin/ansible --version 2>/dev/null | grep -q "core 2\.[2-9][0-9]\|core 2\.1[89]"; then \
	  echo "  ansible-core already >= $(ANSIBLE_MIN_VERSION): $$(~/.local/bin/ansible --version | head -1)"; \
	else \
	  pipx install 'ansible-core>=$(ANSIBLE_MIN_VERSION)' 2>/dev/null || pipx upgrade ansible-core; \
	  echo "  Installed: $$(~/.local/bin/ansible --version | head -1)"; \
	fi
	@if [[ "$$(which ansible 2>/dev/null)" != "$(HOME)/.local/bin/ansible" ]]; then \
	  echo ""; \
	  echo "  ⚠  PATH: 'ansible' resolves to $$(which ansible 2>/dev/null || echo 'not found')"; \
	  echo "     Add this to ~/.bashrc or ~/.zshrc so the pipx version takes priority:"; \
	  echo "       export PATH=\"\$$HOME/.local/bin:\$$PATH\""; \
	fi

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
	@echo "==> Installing Playwright browsers..."
	pnpm exec playwright install chromium

# ---------------------------------------------------------------------------
# setup-galaxy — install Ansible Galaxy collections
# ---------------------------------------------------------------------------
setup-galaxy:
	@echo "==> Installing Ansible Galaxy requirements..."
	~/.local/bin/ansible-galaxy install -r requirements.yml --force
