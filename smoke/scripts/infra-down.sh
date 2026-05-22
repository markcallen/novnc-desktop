#!/usr/bin/env bash
# infra-down.sh — destroy the EC2 smoke test server and clean up local state.
#
# Usage:
#   pnpm infra:down

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/smoke/ec2"
STATE_FILE="$REPO_ROOT/.smoke-state/state.json"

# ---------------------------------------------------------------------------
# 1. Terraform destroy (also removes the Route53 A record when tls_zone was set)
# ---------------------------------------------------------------------------
echo "[infra:down] Destroying Terraform resources..."
cd "$TF_DIR"
terraform destroy -auto-approve -input=false

# ---------------------------------------------------------------------------
# 2. Remove local state (access URL is now invalid)
# ---------------------------------------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
  rm "$STATE_FILE"
  echo "[infra:down] State file removed."
fi

echo "[infra:down] Done. EC2 instance and security group have been destroyed."
