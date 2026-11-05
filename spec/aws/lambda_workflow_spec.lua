-- End-to-end Lambda workflow tests using temporary fake CLI executables.
-- These tests exercise asynchronous process handling without AWS credentials or network access.
local config = require("aws.config")
local workflow = require("aws.lambda.workflow")

local function wait_for(predicate)
  assert.is_true(vim.wait(5000, predicate, 10), "timed out waiting for Lambda workflow")
end

local function executable(path, body)
  vim.fn.writefile(vim.split(body, "\n", { plain = true }), path)
  assert.equals(1, vim.fn.setfperm(path, "rwx------"))
end

local function make_fixture()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/bin", "p")
  vim.fn.writefile({ "fake zip archive" }, root .. "/source.zip")
  vim.fn.writefile({ "print('hello')" }, root .. "/app.py")
  vim.fn.writefile({}, root .. "/aws.log")

  executable(
    root .. "/bin/aws",
    [[#!/bin/sh
printf '%s\n' "$*" >> "$AWS_FAKE_LOG"
case "$*" in
  *"lambda get-function"*) printf '%s\n' '{"Code":{"Location":"https://example.invalid/archive"}}' ;;
  *"sts get-caller-identity"*) printf '%s\n' '123456789012' ;;
  *"configure get region"*) printf '%s\n' 'ap-northeast-1' ;;
  *"lambda update-function-code"*) printf '%s\n' 'updated' ;;
  *"lambda invoke"*)
    for output in "$@"; do last="$output"; done
    printf '%s\n' '{"statusCode":200,"ok":true}' > "$last"
    printf '%s\n' '{"StatusCode":200,"LogResult":""}'
    ;;
  *"logs tail"*) exec sleep 30 ;;
  *) printf 'unexpected aws args: %s\n' "$*" >&2; exit 2 ;;
esac
]]
  )

  executable(
    root .. "/bin/curl",
    [[#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then shift; output="$1"; fi
  shift
done
cp "$AWS_FAKE_ZIP" "$output" || exit 1
printf '100%%\n' >&2
]]
  )

  executable(
    root .. "/bin/unzip",
    [[#!/bin/sh
if [ "$1" = "-Z1" ]; then
  if [ "$AWS_FAKE_UNSAFE" = "1" ]; then printf '%s\n' '../outside.txt'; else printf '%s\n' 'app.py'; fi
  exit 0
fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-d" ]; then shift; output="$1"; fi
  shift
done
mkdir -p "$output" || exit 1
cp "$AWS_FAKE_SOURCE" "$output/app.py"
]]
  )

  executable(
    root .. "/bin/zipinfo",
    [[#!/bin/sh
if [ "$AWS_FAKE_SYMLINK" = "1" ]; then
  printf '%s\n' 'lrwxrwxrwx  3.0 unx 12 b- 12 defN 2026-01-01 00:00 outside-link'
else
  printf '%s\n' '-rw-r--r--  3.0 unx 12 b- 12 defN 2026-01-01 00:00 app.py'
fi
]]
  )

  executable(
    root .. "/bin/zip",
    [[#!/bin/sh
: > "$2"
]]
  )

  return root
end

describe("Lambda workflow", function()
  local fixture
  local old_path
  local old_cwd
  local old_fake_log
  local old_fake_zip
  local old_fake_source
  local old_ui_input
  local old_fake_unsafe
  local old_fake_symlink
  local old_notify

  before_each(function()
    config.setup({})
    fixture = make_fixture()
    old_path, old_cwd = vim.env.PATH, vim.fn.getcwd()
    old_fake_log, old_fake_zip, old_fake_source = vim.env.AWS_FAKE_LOG, vim.env.AWS_FAKE_ZIP, vim.env.AWS_FAKE_SOURCE
    old_ui_input = vim.ui.input
    old_fake_unsafe, old_fake_symlink, old_notify = vim.env.AWS_FAKE_UNSAFE, vim.env.AWS_FAKE_SYMLINK, vim.notify
    vim.env.AWS_FAKE_UNSAFE, vim.env.AWS_FAKE_SYMLINK = nil, nil
    vim.env.PATH = fixture .. "/bin:" .. old_path
    vim.env.AWS_FAKE_LOG = fixture .. "/aws.log"
    vim.env.AWS_FAKE_ZIP = fixture .. "/source.zip"
    vim.env.AWS_FAKE_SOURCE = fixture .. "/app.py"
    vim.cmd.cd(fixture)
  end)

  after_each(function()
    workflow.stop_logs()
    vim.env.PATH, vim.env.AWS_FAKE_LOG = old_path, old_fake_log
    vim.env.AWS_FAKE_ZIP, vim.env.AWS_FAKE_SOURCE = old_fake_zip, old_fake_source
    vim.ui.input = old_ui_input
    vim.env.AWS_FAKE_UNSAFE, vim.env.AWS_FAKE_SYMLINK = old_fake_unsafe, old_fake_symlink
    vim.notify = old_notify
    vim.cmd.cd(old_cwd)
    vim.fn.delete(fixture, "rf")
    config.setup({})
  end)

  it("downloads, binds, and opens the preferred entrypoint asynchronously", function()
    workflow.download_source("payments-api", { profile = "prod", region = "ap-northeast-1" })
    wait_for(function()
      return vim.fn.filereadable(fixture .. "/.aws/lambda/payments-api/.aws-meta.json") == 1
    end)

    local metadata =
      vim.json.decode(table.concat(vim.fn.readfile(fixture .. "/.aws/lambda/payments-api/.aws-meta.json"), "\n"))
    assert.same({ function_name = "payments-api", region = "ap-northeast-1", account = "123456789012" }, metadata)
    assert.equals(fixture .. "/.aws/lambda/payments-api/app.py", vim.api.nvim_buf_get_name(0))
    local calls = table.concat(vim.fn.readfile(fixture .. "/aws.log"), "\n")
    assert.is_truthy(calls:find("--profile prod", 1, true))
    assert.is_truthy(calls:find("lambda get-function", 1, true))
  end)

  it("rejects unsafe archives without replacing the existing source cache", function()
    local dir = fixture .. "/.aws/lambda/payments-api"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "known good source" }, dir .. "/app.py")
    local errors = {}
    vim.notify = function(message)
      table.insert(errors, message)
    end

    vim.env.AWS_FAKE_UNSAFE = "1"
    workflow.download_source("payments-api")
    wait_for(function()
      return table.concat(errors, "\\n"):find("invalid paths", 1, true) ~= nil
    end)
    assert.same({ "known good source" }, vim.fn.readfile(dir .. "/app.py"))

    vim.env.AWS_FAKE_UNSAFE = nil
    vim.env.AWS_FAKE_SYMLINK = "1"
    workflow.download_source("payments-api")
    wait_for(function()
      return table.concat(errors, "\\n"):find("symbolic link", 1, true) ~= nil
    end)
    assert.same({ "known good source" }, vim.fn.readfile(dir .. "/app.py"))
  end)

  it("uploads the bound source and invokes it with a JSON event", function()
    local dir = fixture .. "/.aws/lambda/payments-api"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(
      { vim.json.encode({ function_name = "payments-api", region = "ap-northeast-1", account = "123456789012" }) },
      dir .. "/.aws-meta.json"
    )
    vim.fn.writefile({ "print('updated')" }, dir .. "/app.py")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/app.py"))

    vim.ui.input = function(_, callback)
      callback('{"action":"test"}')
    end
    workflow.upload_and_invoke({ profile = "prod" })
    wait_for(function()
      return vim.api.nvim_buf_get_name(0) == "aws://lambda/invoke/payments-api"
    end)

    local calls = table.concat(vim.fn.readfile(fixture .. "/aws.log"), "\n")
    assert.is_truthy(calls:find("lambda update%-function%-code", 1, false))
    assert.is_truthy(calls:find("lambda invoke", 1, true))
    assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find('"statusCode":200', 1, true))
  end)

  it("deploys saved bound files and ignores ordinary project files", function()
    local dir = fixture .. "/.aws/lambda/payments-api"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(
      { vim.json.encode({ function_name = "payments-api", region = "ap-northeast-1" }) },
      dir .. "/.aws-meta.json"
    )
    vim.fn.writefile({ "print('saved')" }, dir .. "/handler.py")
    config.setup({ lambda = { auto_deploy = true } })
    workflow.setup_auto_deploy(true)

    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))
    vim.cmd("write")
    wait_for(function()
      return table.concat(vim.fn.readfile(fixture .. "/aws.log"), "\n"):find("lambda update%-function%-code", 1, false)
        ~= nil
    end)

    vim.fn.writefile({ "ordinary" }, fixture .. "/outside.py")
    vim.cmd.edit(vim.fn.fnameescape(fixture .. "/outside.py"))
    vim.cmd("write")
    vim.wait(100)
    local calls = table.concat(vim.fn.readfile(fixture .. "/aws.log"), "\n")
    local _, count = calls:gsub("lambda update%-function%-code", "")
    assert.equals(1, count)
  end)

  it("stops and reconnects live logs without blocking", function()
    local dir = fixture .. "/.aws/lambda/payments-api"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(
      { vim.json.encode({ function_name = "payments-api", region = "ap-northeast-1" }) },
      dir .. "/.aws-meta.json"
    )
    vim.fn.writefile({ "pass" }, dir .. "/app.py")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/app.py"))
    workflow.tail_logs({ profile = "prod" })
    local logbuf = vim.api.nvim_get_current_buf()
    assert.equals("aws://lambda/logs/prod|ap-northeast-1|payments-api", vim.api.nvim_buf_get_name(logbuf))
    workflow.stop_logs()
    vim.wait(100)
    workflow.tail_logs({ profile = "prod" })
    assert.equals("aws://lambda/logs/prod|ap-northeast-1|payments-api", vim.api.nvim_buf_get_name(0))
    workflow.stop_logs()
  end)
end)
