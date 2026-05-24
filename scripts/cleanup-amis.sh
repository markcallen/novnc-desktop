#!/usr/bin/env bash
# cleanup-amis.sh — deregister AMIs and delete snapshots created by this project
#
# Usage:
#   ./scripts/cleanup-amis.sh [OPTIONS]
#
# Options:
#   --region <region>          AWS region (default: us-east-1)
#   --environment <env>        Filter by Environment tag: test|production|all (default: test)
#   --variant <variant>        Filter by Variant tag: openbox|elementary|all (default: all)
#   --prefix <prefix>          Filter by AMI name prefix (default: novnc-desktop-ubuntu-24.04)
#   --keep <n>                 Keep the N most recent AMIs per variant (default: 0 — delete all)
#   --dry-run                  Print what would be deleted without deleting anything
#   --yes                      Skip confirmation prompt
#
# Examples:
#   # Preview what would be cleaned up (test AMIs only):
#   ./scripts/cleanup-amis.sh --dry-run
#
#   # Delete all test AMIs without confirmation:
#   ./scripts/cleanup-amis.sh --yes
#
#   # Delete all production AMIs, keeping the 2 most recent per variant:
#   ./scripts/cleanup-amis.sh --environment production --keep 2
#
#   # Delete only openbox AMIs in us-west-2:
#   ./scripts/cleanup-amis.sh --region us-west-2 --variant openbox
#
#   # Delete everything (test + production):
#   ./scripts/cleanup-amis.sh --environment all --yes

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="test"
VARIANT="all"
AMI_NAME_PREFIX="${AMI_NAME_PREFIX:-novnc-desktop-ubuntu-24.04}"
KEEP=0
DRY_RUN=false
AUTO_YES=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      AWS_REGION="$2"; shift 2 ;;
    --environment)
      ENVIRONMENT="$2"; shift 2 ;;
    --variant)
      VARIANT="$2"; shift 2 ;;
    --prefix)
      AMI_NAME_PREFIX="$2"; shift 2 ;;
    --keep)
      KEEP="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --yes)
      AUTO_YES=true; shift ;;
    -h|--help)
      sed -n '2,/^set /p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if [[ "$ENVIRONMENT" != "test" && "$ENVIRONMENT" != "production" && "$ENVIRONMENT" != "all" ]]; then
  echo "ERROR: --environment must be test, production, or all" >&2
  exit 1
fi

if [[ "$VARIANT" != "openbox" && "$VARIANT" != "elementary" && "$VARIANT" != "all" ]]; then
  echo "ERROR: --variant must be openbox, elementary, or all" >&2
  exit 1
fi

if ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --keep must be a non-negative integer" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
if ! command -v aws &>/dev/null; then
  echo "ERROR: aws CLI not found. Install it from https://aws.amazon.com/cli/" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install it with: brew install jq  or  apt-get install jq" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build tag filters
# ---------------------------------------------------------------------------
FILTERS=(
  "Name=tag:Project,Values=novnc-desktop"
  "Name=tag:BuildTool,Values=Packer"
  "Name=state,Values=available"
)

if [[ "$ENVIRONMENT" != "all" ]]; then
  FILTERS+=("Name=tag:Environment,Values=$ENVIRONMENT")
fi

if [[ "$VARIANT" != "all" ]]; then
  FILTERS+=("Name=tag:Variant,Values=$VARIANT")
fi

# Also filter by name prefix to avoid matching unrelated project AMIs
FILTERS+=("Name=name,Values=${AMI_NAME_PREFIX}-*")

# ---------------------------------------------------------------------------
# Discover AMIs
# ---------------------------------------------------------------------------
echo "=========================================="
echo "noVNC Desktop AMI Cleanup"
echo "=========================================="
echo "Region:      $AWS_REGION"
echo "Environment: $ENVIRONMENT"
echo "Variant:     $VARIANT"
echo "Name prefix: $AMI_NAME_PREFIX"
echo "Keep:        $KEEP most recent per variant"
echo "Dry run:     $DRY_RUN"
echo ""

echo "Discovering AMIs..."
IMAGES_JSON=$(aws ec2 describe-images \
  --region "$AWS_REGION" \
  --owners self \
  --filters "${FILTERS[@]}" \
  --query 'Images[*].{ImageId:ImageId,Name:Name,CreationDate:CreationDate,SnapshotIds:BlockDeviceMappings[*].Ebs.SnapshotId,Variant:Tags[?Key==`Variant`]|[0].Value,Environment:Tags[?Key==`Environment`]|[0].Value}' \
  --output json)

TOTAL=$(echo "$IMAGES_JSON" | jq 'length')

if [[ "$TOTAL" -eq 0 ]]; then
  echo "No matching AMIs found."
  exit 0
fi

echo "Found $TOTAL AMI(s):"
echo ""
echo "$IMAGES_JSON" | jq -r '.[] | "  \(.ImageId)  \(.Name)  [\(.Environment)/\(.Variant)]"' | sort
echo ""

# ---------------------------------------------------------------------------
# Apply --keep filter: for each variant group, skip the N newest
# ---------------------------------------------------------------------------
TO_DELETE_JSON="[]"

if [[ "$KEEP" -gt 0 ]]; then
  # Process each variant separately
  VARIANTS_PRESENT=$(echo "$IMAGES_JSON" | jq -r '[.[].Variant] | unique | .[]')
  for v in $VARIANTS_PRESENT; do
    GROUP=$(echo "$IMAGES_JSON" | jq --arg v "$v" '[.[] | select(.Variant == $v)] | sort_by(.CreationDate)')
    GROUP_COUNT=$(echo "$GROUP" | jq 'length')
    DELETE_COUNT=$(( GROUP_COUNT - KEEP ))
    if [[ "$DELETE_COUNT" -le 0 ]]; then
      echo "Variant '$v': $GROUP_COUNT AMI(s) — keeping all (≤ $KEEP)."
      continue
    fi
    echo "Variant '$v': $GROUP_COUNT AMI(s) — will delete $DELETE_COUNT, keep $KEEP."
    OLDEST=$(echo "$GROUP" | jq --argjson n "$DELETE_COUNT" '.[:$n]')
    TO_DELETE_JSON=$(echo "$TO_DELETE_JSON $OLDEST" | jq -s 'add')
  done
else
  TO_DELETE_JSON="$IMAGES_JSON"
fi

DELETE_COUNT=$(echo "$TO_DELETE_JSON" | jq 'length')

if [[ "$DELETE_COUNT" -eq 0 ]]; then
  echo "Nothing to delete."
  exit 0
fi

echo ""
echo "AMIs to delete ($DELETE_COUNT):"
echo "$TO_DELETE_JSON" | jq -r '.[] | "  \(.ImageId)  \(.Name)"' | sort
echo ""

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY RUN] No changes made."
  exit 0
fi

if [[ "$AUTO_YES" != "true" ]]; then
  read -r -p "Delete $DELETE_COUNT AMI(s) and their snapshots in $AWS_REGION? [y/N] " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Delete AMIs and associated snapshots
# ---------------------------------------------------------------------------
ERRORS=0

while IFS= read -r row; do
  IMAGE_ID=$(echo "$row" | jq -r '.ImageId')
  NAME=$(echo "$row" | jq -r '.Name')
  SNAPSHOT_IDS=$(echo "$row" | jq -r '.SnapshotIds[]? // empty')

  echo "Deregistering $IMAGE_ID ($NAME)..."
  if aws ec2 deregister-image \
    --region "$AWS_REGION" \
    --image-id "$IMAGE_ID" 2>&1; then
    echo "  Deregistered $IMAGE_ID"
  else
    echo "  ERROR: Failed to deregister $IMAGE_ID" >&2
    ERRORS=$(( ERRORS + 1 ))
    continue
  fi

  for SNAP_ID in $SNAPSHOT_IDS; do
    echo "  Deleting snapshot $SNAP_ID..."
    if aws ec2 delete-snapshot \
      --region "$AWS_REGION" \
      --snapshot-id "$SNAP_ID" 2>&1; then
      echo "  Deleted snapshot $SNAP_ID"
    else
      echo "  ERROR: Failed to delete snapshot $SNAP_ID" >&2
      ERRORS=$(( ERRORS + 1 ))
    fi
  done

done < <(echo "$TO_DELETE_JSON" | jq -c '.[]')

echo ""
if [[ "$ERRORS" -gt 0 ]]; then
  echo "Cleanup finished with $ERRORS error(s). Review output above."
  exit 1
else
  echo "Cleanup complete. Deleted $DELETE_COUNT AMI(s)."
fi
