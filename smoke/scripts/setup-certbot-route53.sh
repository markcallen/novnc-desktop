#!/usr/bin/env bash
# setup-certbot-route53.sh — create/update IAM resources for certbot DNS-01 and
# verify Route53 zone/domain visibility in the current AWS account.
#
# Usage:
#   bash smoke/scripts/setup-certbot-route53.sh --zone smoke.markcallen.dev
#   bash smoke/scripts/setup-certbot-route53.sh --domain gentle-monster.smoke.markcallen.dev
#   bash smoke/scripts/setup-certbot-route53.sh --zone smoke.markcallen.dev --profile prod

set -euo pipefail

POLICY_NAME="${POLICY_NAME:-novnc-certbot-route53}"
ROLE_NAME="${ROLE_NAME:-novnc-desktop-certbot}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-novnc-desktop-certbot}"
ZONE_NAME="${ZONE_NAME:-}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --zone <name>            Route53 hosted zone name to verify (e.g. smoke.markcallen.dev)
  --domain <fqdn>          Domain to verify against hosted zones (walks parent labels)
  --profile <aws-profile>  AWS CLI profile to use
  --region <aws-region>    AWS region for AWS CLI calls (default: us-east-1)
  --help                   Show this help text

At least one of --zone or --domain is required.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zone)
      ZONE_NAME="$2"
      shift 2
      ;;
    --domain)
      DOMAIN_NAME="$2"
      shift 2
      ;;
    --profile)
      AWS_PROFILE="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    --*)
      echo "ERROR: Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      echo "ERROR: Unexpected argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$ZONE_NAME" && -z "$DOMAIN_NAME" ]]; then
  echo "ERROR: Provide --zone or --domain." >&2
  usage
  exit 1
fi

AWS_ARGS=(--region "$AWS_REGION")
if [[ -n "$AWS_PROFILE" ]]; then
  AWS_ARGS+=(--profile "$AWS_PROFILE")
fi

normalize_fqdn() {
  local v="$1"
  v="${v%.}"
  echo "$v"
}

ZONE_NAME="$(normalize_fqdn "$ZONE_NAME")"
DOMAIN_NAME="$(normalize_fqdn "$DOMAIN_NAME")"

echo "[setup-certbot-route53] Using role=$ROLE_NAME policy=$POLICY_NAME instance-profile=$INSTANCE_PROFILE_NAME"

find_best_matching_zone() {
  local fqdn
  fqdn="$(normalize_fqdn "$1")"
  while [[ -n "$fqdn" ]]; do
    if aws route53 list-hosted-zones "${AWS_ARGS[@]}" \
      --query "HostedZones[?Name=='${fqdn}.'].Name" \
      --output text | grep -q .; then
      echo "$fqdn"
      return 0
    fi
    if [[ "$fqdn" != *.* ]]; then
      break
    fi
    fqdn="${fqdn#*.}"
  done
  return 1
}

get_zone_id_by_name() {
  local zone_name="$1"
  aws route53 list-hosted-zones "${AWS_ARGS[@]}" \
    --query "HostedZones[?Name=='${zone_name}.'].Id | [0]" \
    --output text
}

# Resolve and verify zone/domain first so IAM policy can be scoped.
RESOLVED_ZONE_NAME=""
RESOLVED_ZONE_ID=""

if [[ -n "$ZONE_NAME" ]]; then
  ZONE_ID=$(get_zone_id_by_name "$ZONE_NAME")
  if [[ -z "$ZONE_ID" || "$ZONE_ID" == "None" ]]; then
    echo "[setup-certbot-route53] ERROR: Route53 zone not found: ${ZONE_NAME}." >&2
    exit 1
  fi
  RESOLVED_ZONE_NAME="$ZONE_NAME"
  RESOLVED_ZONE_ID="$ZONE_ID"
  echo "[setup-certbot-route53] Route53 zone found: ${ZONE_NAME}."
fi

if [[ -n "$DOMAIN_NAME" ]]; then
  if MATCHED_ZONE=$(find_best_matching_zone "$DOMAIN_NAME"); then
    echo "[setup-certbot-route53] Domain $DOMAIN_NAME is covered by hosted zone: ${MATCHED_ZONE}."
    if [[ -z "$RESOLVED_ZONE_NAME" ]]; then
      RESOLVED_ZONE_NAME="$MATCHED_ZONE"
      RESOLVED_ZONE_ID=$(get_zone_id_by_name "$MATCHED_ZONE")
    fi
  else
    echo "[setup-certbot-route53] ERROR: No Route53 hosted zone found for domain: $DOMAIN_NAME" >&2
    exit 1
  fi
fi

if [[ -z "$RESOLVED_ZONE_ID" || "$RESOLVED_ZONE_ID" == "None" ]]; then
  echo "[setup-certbot-route53] ERROR: Could not resolve hosted zone ID." >&2
  exit 1
fi

ZONE_ID_STRIPPED="${RESOLVED_ZONE_ID##*/}"
CHANGE_RRSET_RESOURCE="arn:aws:route53:::hostedzone/${ZONE_ID_STRIPPED}"

ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_ARGS[@]}" --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

TMP_POLICY_JSON=$(mktemp)
cat > "$TMP_POLICY_JSON" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CertbotListHostedZones",
      "Effect": "Allow",
      "Action": ["route53:ListHostedZones"],
      "Resource": "*"
    },
    {
      "Sid": "CertbotGetChange",
      "Effect": "Allow",
      "Action": ["route53:GetChange"],
      "Resource": "arn:aws:route53:::change/*"
    },
    {
      "Sid": "CertbotChangeResourceRecordSets",
      "Effect": "Allow",
      "Action": ["route53:ChangeResourceRecordSets"],
      "Resource": "${CHANGE_RRSET_RESOURCE}"
    }
  ]
}
POLICY

if aws iam get-policy "${AWS_ARGS[@]}" --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "[setup-certbot-route53] Policy exists: $POLICY_ARN (updating document)"
  POLICY_VERSION_COUNT=$(aws iam list-policy-versions "${AWS_ARGS[@]}" \
    --policy-arn "$POLICY_ARN" --query 'length(Versions)' --output text)

  if [[ "$POLICY_VERSION_COUNT" -ge 5 ]]; then
    OLDEST_NONDEFAULT=$(aws iam list-policy-versions "${AWS_ARGS[@]}" \
      --policy-arn "$POLICY_ARN" \
      --query 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId' \
      --output text)
    if [[ -n "$OLDEST_NONDEFAULT" && "$OLDEST_NONDEFAULT" != "None" ]]; then
      aws iam delete-policy-version "${AWS_ARGS[@]}" \
        --policy-arn "$POLICY_ARN" --version-id "$OLDEST_NONDEFAULT" >/dev/null
    fi
  fi

  aws iam create-policy-version "${AWS_ARGS[@]}" \
    --policy-arn "$POLICY_ARN" \
    --policy-document "file://$TMP_POLICY_JSON" \
    --set-as-default >/dev/null
else
  echo "[setup-certbot-route53] Creating policy: $POLICY_NAME"
  aws iam create-policy "${AWS_ARGS[@]}" \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$TMP_POLICY_JSON" >/dev/null
fi
rm -f "$TMP_POLICY_JSON"

if aws iam get-role "${AWS_ARGS[@]}" --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "[setup-certbot-route53] Role exists: $ROLE_NAME"
else
  echo "[setup-certbot-route53] Creating role: $ROLE_NAME"
  TMP_TRUST_JSON=$(mktemp)
  cat > "$TMP_TRUST_JSON" <<TRUST
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
TRUST
  aws iam create-role "${AWS_ARGS[@]}" \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TMP_TRUST_JSON" >/dev/null
  rm -f "$TMP_TRUST_JSON"
fi

echo "[setup-certbot-route53] Attaching policy to role"
aws iam attach-role-policy "${AWS_ARGS[@]}" \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN" >/dev/null

if aws iam get-instance-profile "${AWS_ARGS[@]}" --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  echo "[setup-certbot-route53] Instance profile exists: $INSTANCE_PROFILE_NAME"
else
  echo "[setup-certbot-route53] Creating instance profile: $INSTANCE_PROFILE_NAME"
  aws iam create-instance-profile "${AWS_ARGS[@]}" \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
fi

PROFILE_ROLE_NAMES=$(aws iam get-instance-profile "${AWS_ARGS[@]}" \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output text)

if grep -qw "$ROLE_NAME" <<<"$PROFILE_ROLE_NAMES"; then
  echo "[setup-certbot-route53] Role already present in instance profile"
else
  echo "[setup-certbot-route53] Adding role to instance profile"
  aws iam add-role-to-instance-profile "${AWS_ARGS[@]}" \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$ROLE_NAME" >/dev/null
fi

# IAM propagation can take a short time.
echo "[setup-certbot-route53] Waiting 10s for IAM propagation..."
sleep 10

echo "[setup-certbot-route53] Done."
echo "[setup-certbot-route53] Instance profile ready: $INSTANCE_PROFILE_NAME"
echo "[setup-certbot-route53] Policy scoped to hosted zone: ${RESOLVED_ZONE_NAME} (${ZONE_ID_STRIPPED})"
