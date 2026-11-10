#!/bin/sh
# Create a disposable workspace wired to the mock AWS CLI.
#
#   sh docs/mock-data/setup-demo.sh [target-dir]
#
# The script only writes files under the target directory (default:
# /tmp/aws-nvim-mock) and prints the exports to run in your shell.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target=${1:-/tmp/aws-nvim-mock}

case "$target" in
  -h|--help)
    printf 'usage: %s [target-dir]\n' "$0"
    exit 0
    ;;
esac

rm -rf "$target"
mkdir -p "$target/lambda/dwh-dev"

cat >"$target/lambda/dwh-dev/handler.py" <<'PY'
import json


def handler(event, context):
    return {"statusCode": 200, "body": json.dumps(event)}
PY

printf '{\n  "order": "42",\n  "source": "mock"\n}\n' >"$target/lambda/dwh-dev/invoke.json"
printf '{"statusCode":200}\n' >"$target/lambda/dwh-dev/response.json"
cat >"$target/lambda/dwh-dev/.aws-resource.json" <<'JSON'
{"type":"lambda","account":"123456789012","region":"ap-northeast-1","profile":"dev","function_name":"dwh-dev","log_group":"/aws/lambda/dwh-dev"}
JSON
cat >"$target/lambda/dwh-dev/.aws-meta.json" <<'JSON'
{"function_name":"dwh-dev","region":"ap-northeast-1","account":"123456789012"}
JSON
: >"$target/aws.log"

cat <<EOF
Mock workspace ready: $target

export PATH="$here/bin:\$PATH"
export AWS_CONFIG_FILE="$here/aws-config"
export AWS_PROFILE=dev
export AWS_FAKE_LOG="$target/aws.log"

cd "$target"
nvim lambda/dwh-dev/handler.py

Then try:
  :AwsProfile              pick a profile (dev/stg/prod/sandbox/no-region)
  :AwsProfile stg          switch directly
  :AwsLambda               browse the mock functions (d, e, i, v, r work)
  :AwsKMS                  browse mock KMS aliases and keys
  :AwsInvoke               invoke with lambda/dwh-dev/invoke.json
  :AwsLogs                 stream a few mock CloudWatch lines

Every call is appended to $target/aws.log as "<profile> <args>".
EOF
