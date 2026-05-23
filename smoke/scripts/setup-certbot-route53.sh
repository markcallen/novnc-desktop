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

ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_ARGS[@]}" --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "[setup-certbot-route53] Policy exists: $POLICY_ARN"
else
  echo "[setup-certbot-route53] Creating policy: $POLICY_NAME"
  TMP_POLICY_JSON=$(mktemp)
  cat > "$TMP_POLICY_JSON" <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CertbotRoute53",
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:GetChange",
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$TMP_POLICY_JSON" >/dev/null
  rm -f "$TMP_POLICY_JSON"
fi

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
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
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TMP_TRUST_JSON" >/dev/null
  rm -f "$TMP_TRUST_JSON"
fi

echo "[setup-certbot-route53] Attaching policy to role"
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN" >/dev/null

if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  echo "[setup-certbot-route53] Instance profile exists: $INSTANCE_PROFILE_NAME"
else
  echo "[setup-certbot-route53] Creating instance profile: $INSTANCE_PROFILE_NAME"
  aws iam create-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
fi

PROFILE_ROLE_NAMES=$(aws iam get-instance-profile \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --query 'InstanceProfile.Roles[].RoleName' \
  --output text)

if grep -qw "$ROLE_NAME" <<<"$PROFILE_ROLE_NAMES"; then
  echo "[setup-certbot-route53] Role already present in instance profile"
else
  echo "[setup-certbot-route53] Adding role to instance profile"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --role-name "$ROLE_NAME" >/dev/null
fi

# IAM propagation can take a short time.
echo "[setup-certbot-route53] Waiting 10s for IAM propagation..."
sleep 10

find_best_matching_zone() {
  local fqdn
  fqdn="$(normalize_fqdn "$1")"
  while [[ -n "$fqdn" ]]; do
    if aws route53 list-hosted-zones "${AWS_ARGS[@]}" \
      --query "HostedZones[?Name=='${fqdn}.'].[Id,Name]" \
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

if [[ -n "$ZONE_NAME" ]]; then
  if aws route53 list-hosted-zones "${AWS_ARGS[@]}" \
    --query "HostedZones[?Name=='${ZONE_NAME}.'].[Id,Name]" \
    --output text | grep -q .; then
    echo "[setup-certbot-route53] Route53 zone found: ${ZONE_NAME}."
  else
    echo "[setup-certbot-route53] ERROR: Route53 zone not found: ${ZONE_NAME}." >&2
    exit 1
  fi
fi

if [[ -n "$DOMAIN_NAME" ]]; then
  if MATCHED_ZONE=$(find_best_matching_zone "$DOMAIN_NAME"); then
    echo "[setup-certbot-route53] Domain $DOMAIN_NAME is covered by hosted zone: ${MATCHED_ZONE}."
  else
    echo "[setup-certbot-route53] ERROR: No Route53 hosted zone found for domain: $DOMAIN_NAME" >&2
    exit 1
  fi
fi

echo "[setup-certbot-route53] Done."
echo "[setup-certbot-route53] Instance profile ready: $INSTANCE_PROFILE_NAME"
