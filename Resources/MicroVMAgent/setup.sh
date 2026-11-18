#!/bin/bash
# One-time setup for Studio's AWS Lambda MicroVMs sandbox provider. Safe to re-run (it updates in place).
#
# Creates in your AWS account (region from AWS_REGION / your CLI config, default us-east-1):
#   - S3 bucket   studio-microvm-<account>-<region>   (private; holds the image's build artifact)
#   - IAM roles   StudioMicroVMBuildRole, StudioMicroVMExecutionRole   (trust lambda.amazonaws.com, this account only)
#   - MicroVM image  studio-sandbox  (Amazon Linux 2023 dev box + Studio's agent)
# and records the image in Studio's settings. Costs: image storage, plus MicroVM time while sandboxes run.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
STUDIO_DOMAIN="${STUDIO_DOMAIN:-dev.local.studio}"
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION:-$(aws configure get region || true)}"; REGION="${REGION:-us-east-1}"
export AWS_REGION="$REGION"
say "Account $ACCOUNT, region $REGION"

say "Checking Lambda MicroVMs in $REGION…"
BASE=$(aws lambda-microvms list-managed-microvm-images --output json | python3 -c '
import json,sys
d=json.load(sys.stdin); items=next((v for v in d.values() if isinstance(v,list)),[])
arns=[i.get("imageArn") or i.get("arn") for i in items]; arns=[a for a in arns if a]
print(next((a for a in arns if "al2023" in a), arns[0] if arns else ""))')
[ -n "$BASE" ] || { echo "Lambda MicroVMs isn't available in $REGION (no managed images)."; exit 1; }
echo "base image: $BASE"

BUCKET="studio-microvm-$ACCOUNT-$REGION"
say "S3 bucket $BUCKET"
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null; fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

TRUST=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},
 "Action":"sts:AssumeRole","Condition":{"StringEquals":{"aws:SourceAccount":"$ACCOUNT"}}}]}
JSON
)
role() {  # name, inline policy json
  if ! aws iam get-role --role-name "$1" >/dev/null 2>&1; then
    aws iam create-role --role-name "$1" --assume-role-policy-document "$TRUST" >/dev/null
    CREATED_ROLE=1
  fi
  aws iam put-role-policy --role-name "$1" --policy-name studio --policy-document "$2"
}
CREATED_ROLE=0
say "IAM roles"
LOGS='{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"arn:aws:logs:'"$REGION:$ACCOUNT"':log-group:/aws/lambda-microvms/*"}'
role StudioMicroVMBuildRole '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::'"$BUCKET"'/*"},'"$LOGS"']}'
role StudioMicroVMExecutionRole '{"Version":"2012-10-17","Statement":['"$LOGS"']}'
[ "$CREATED_ROLE" = 1 ] && { echo "waiting for new roles to propagate…"; sleep 12; }
BUILD_ROLE="arn:aws:iam::$ACCOUNT:role/StudioMicroVMBuildRole"
EXEC_ROLE="arn:aws:iam::$ACCOUNT:role/StudioMicroVMExecutionRole"

say "Uploading the Studio sandbox image artifact"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
(cd "$here" && zip -q "$TMP/studio-sandbox.zip" Dockerfile agent.py)
KEY="studio-sandbox/$(date +%s).zip"
aws s3 cp "$TMP/studio-sandbox.zip" "s3://$BUCKET/$KEY" >/dev/null

HOOKS='{"port":9000,"microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":120}}'
IMAGE_ARN="arn:aws:lambda:$REGION:$ACCOUNT:microvm-image:studio-sandbox"
if aws lambda-microvms get-microvm-image --image-identifier "$IMAGE_ARN" >/dev/null 2>&1; then
  say "Building a new version of studio-sandbox"
  OUT=$(aws lambda-microvms update-microvm-image --image-identifier "$IMAGE_ARN" --base-image-arn "$BASE" \
        --build-role-arn "$BUILD_ROLE" --code-artifact "{\"uri\":\"s3://$BUCKET/$KEY\"}" --hooks "$HOOKS" --output json)
else
  say "Building image studio-sandbox (a few minutes)"
  OUT=$(aws lambda-microvms create-microvm-image --name studio-sandbox --description "Studio sandbox" \
        --base-image-arn "$BASE" --build-role-arn "$BUILD_ROLE" \
        --code-artifact "{\"uri\":\"s3://$BUCKET/$KEY\"}" --hooks "$HOOKS" --output json)
fi
IMAGE_ARN=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("imageArn",""))')
VERSION=$(echo "$OUT" | python3 -c '
import json,sys; d=json.load(sys.stdin)
print(next((str(v) for k,v in d.items() if k.lower() in ("version","imageversion","latestversion")), ""))')

say "Waiting for the build…"
for i in $(seq 1 120); do
  ST=$(aws lambda-microvms get-microvm-image --image-identifier "$IMAGE_ARN" --output json)
  read -r STATE VSTATE V <<<"$(echo "$ST" | python3 -c '
import json,sys; d=json.load(sys.stdin)
vs=d.get("latestVersion") or d.get("version") or {}
if not isinstance(vs,dict): vs={"version":vs}
print(d.get("state","?"), vs.get("state", d.get("versionState","?")), vs.get("version", d.get("imageVersion","")))')"
  [ -n "${V:-}" ] && [ "$V" != "None" ] && VERSION="$V"
  printf '\r  image %s · version %s %s   ' "$STATE" "${VERSION:-?}" "$VSTATE"
  case "$VSTATE" in SUCCESSFUL) echo; break ;; FAILED) echo; echo "$ST"; exit 1 ;; esac
  sleep 10
done

defaults write "$STUDIO_DOMAIN" sandbox.aws.imageArn "$IMAGE_ARN"
defaults write "$STUDIO_DOMAIN" sandbox.aws.imageVersion "$VERSION"
defaults write "$STUDIO_DOMAIN" sandbox.aws.executionRoleArn "$EXEC_ROLE"
defaults write "$STUDIO_DOMAIN" sandbox.aws.region "$REGION"
say "Done. Studio can now create AWS MicroVM sandboxes ($IMAGE_ARN, version $VERSION)."
