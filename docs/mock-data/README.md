# Mock AWS data for aws.nvim

Everything here is fake. Use it to exercise aws.nvim — browsing, download, upload, invoke, logs, KMS, profile switching — without an AWS account, credentials or network access. The same fixtures back `spec/aws/mock_data_spec.lua`, so they cannot silently rot.

## Contents

| Path | Purpose |
|---|---|
| `bin/` | Mock `aws`, `curl`, `unzip`, `zipinfo` and `zip` executables. `bin/aws` logs every call as `<profile> <args>` and answers Lambda, CloudWatch Logs, KMS, CloudFormation and S3 calls. |
| `aws-config` | Sanitized `~/.aws/config`: `default`, `dev`, `stg`, `prod`, `sandbox`, a region-less `no-region`, plus an `[sso-session]` section that must be ignored. |
| `setup-demo.sh` | Creates a disposable workspace with a bound Lambda (`handler.py`, `invoke.json`, `response.json`, metadata) wired to the mocks. |

## Quick start

```sh
# 1. build the mock workspace and print the exports
sh docs/mock-data/setup-demo.sh

# 2. run the exports it prints, e.g.
export PATH="$PWD/docs/mock-data/bin:$PATH"
export AWS_CONFIG_FILE="$PWD/docs/mock-data/aws-config"
export AWS_PROFILE=dev
export AWS_FAKE_LOG=/tmp/aws-nvim-mock/aws.log

# 3. open Neovim in the workspace
cd /tmp/aws-nvim-mock && nvim lambda/dwh-dev/handler.py
```

Inside Neovim:

| Command / key | What to expect with the mocks |
|---|---|
| `:AwsProfile` | Picker with `default, dev, stg, prod, sandbox, no-region`; selecting one sets `$AWS_PROFILE` and redraws the statusline. |
| `:AwsProfile stg` | Statusline becomes `󰸏 stg@ap-northeast-1`. |
| `:AwsLambda` | Two functions (`dwh-dev`, `payments-api`). |
| `D` / `E` | Download uses the mock `curl`/`unzip`/`zipinfo` chain and writes `lambda/<name>/`. |
| `e` / `i` / `v` | Edit `invoke.json`, invoke it (response body echoes the profile), view `response.json`. |
| `r` | Upload + invoke; `function.zip` is built by the mock `zip`. |
| `:AwsInvoke`, `:AwsUpload`, `:AwsLogs`, `:AwsRefresh`, `:AwsMetadata` | Resource actions against the mock data. |
| `:AwsKMS` | Three mock keys, one without an alias; `<CR>` describes the key. |
| `:AwsCF`, `:AwsS3` | One mock stack / one mock bucket. |

## Failure simulation

```sh
export AWS_FAKE_FAIL=1   # lambda update-function-code returns AccessDeniedException
```

The plugin must show `❌ Upload Failed` with the raw AWS CLI error.

## Verifying profile propagation

Every mock call appends `<profile> <args>` to `$AWS_FAKE_LOG`:

```sh
tail -n 5 "$AWS_FAKE_LOG"
# dev --profile dev --region ap-northeast-1 lambda invoke --function-name dwh-dev ...
```

If a call shows the wrong profile, the plugin passed the wrong `--profile` or the statusline/env got out of sync.

## Notes

- Nothing here talks to AWS; the `mock://` code URLs never leave the machine.
- Account IDs (`123456789012`), roles and ARNs are fictional.
- To point the mocks at a different profile file, override `AWS_CONFIG_FILE`.
