-- Unified resource actions: discovery, download, invoke, logs, refresh, metadata.
local config = require("aws.config")
local resource = require("aws.resource")

local function executable(path, body)
  vim.fn.writefile(vim.split(body, "\n", { plain = true }), path)
  assert.equals(1, vim.fn.setfperm(path, "rwx------"))
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function make_fixture()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/bin", "p")
  vim.fn.writefile({}, root .. "/aws.log")
  vim.fn.writefile({ "fake zip archive" }, root .. "/source.zip")
  vim.fn.writefile({ "print('hello')" }, root .. "/app.py")

  executable(
    root .. "/bin/aws",
    [[#!/bin/sh
printf '%s\n' "$*" >> "$AWS_FAKE_LOG"
case "$*" in
  *"lambda get-function "*) printf '%s\n' '{"Code":{"Location":"https://example.invalid/archive"}}' ;;
  *"lambda get-function-configuration"*)
    printf '%s\n' '{"FunctionName":"dwh-dev","Runtime":"python3.12","Architectures":["x86_64"],"MemorySize":512,"Timeout":30,"Handler":"handler.handler","CodeSha256":"abc123","CodeSize":734,"LastModified":"2026-11-09T04:40:12.000+0000","Environment":{"Variables":{"DB_HOST":"db","STAGE":"dev"}}}'
    ;;
  *"lambda invoke"*)
    for out in "$@"; do case "$out" in *.json) last="$out" ;; esac; done
    printf '%s\n' '{"statusCode":200,"ok":true}' > "$last"
    printf '%s\n' '{"StatusCode":200,"ExecutedVersion":"$LATEST"}'
    ;;
  *"sts get-caller-identity"*) printf '%s\n' '123456789012' ;;
  *"configure get region"*) printf '%s\n' 'ap-northeast-1' ;;
  *) printf 'unexpected aws args: %s\n' "$*" >&2; exit 2 ;;
esac
]]
  )

  executable(
    root .. "/bin/curl",
    [[#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then shift; out="$1"; fi
  shift
done
cp "$AWS_FAKE_ZIP" "$out"
]]
  )
  executable(
    root .. "/bin/unzip",
    [[#!/bin/sh
if [ "$1" = "-Z1" ]; then printf 'app.py\n'; exit 0; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-d" ]; then shift; dest="$1"; fi
  shift
done
mkdir -p "$dest"
cp "$AWS_FAKE_SOURCE" "$dest/app.py"
]]
  )
  executable(
    root .. "/bin/zipinfo",
    [[#!/bin/sh
printf '%s\n' '-rw-r--r--  3.0 unx 12 b- 12 defN 2026-01-01 00:00 app.py'
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

describe("AWS resource actions", function()
  local fixture
  local old_env = {}

  before_each(function()
    config.setup({})
    resource.last_result = nil
    fixture = make_fixture()
    for _, key in ipairs({ "PATH", "AWS_FAKE_LOG", "AWS_FAKE_ZIP", "AWS_FAKE_SOURCE" }) do
      old_env[key] = vim.env[key]
    end
    vim.env.PATH = fixture .. "/bin:" .. old_env.PATH
    vim.env.AWS_FAKE_LOG = fixture .. "/aws.log"
    vim.env.AWS_FAKE_ZIP = fixture .. "/source.zip"
    vim.env.AWS_FAKE_SOURCE = fixture .. "/app.py"
    vim.cmd.cd(fixture)
  end)

  after_each(function()
    for key, value in pairs(old_env) do
      vim.env[key] = value
    end
    vim.cmd.cd(fixture)
    vim.fn.delete(fixture, "rf")
    resource.last_result = nil
  end)

  local function make_resource(dir, extra)
    local data = vim.tbl_extend("force", {
      type = "lambda",
      account = "123456789012",
      region = "ap-northeast-1",
      profile = "sbi-dwh-dev",
      function_name = "dwh-dev",
      log_group = "/aws/lambda/dwh-dev",
    }, extra or {})
    write(dir .. "/.aws-resource.json", { vim.json.encode(data) })
    write(dir .. "/handler.py", { "print('hi')" })
    return dir
  end

  it("reads type, account, region, profile and log_group from metadata", function()
    local dir = make_resource(fixture .. "/aws-dev/lambda/dwh-dev")
    local found = resource.discover(dir .. "/handler.py")
    assert.equals("lambda", found.type)
    assert.equals("dwh-dev", found.name)
    assert.equals("123456789012", found.account)
    assert.equals("ap-northeast-1", found.region)
    assert.equals("sbi-dwh-dev", found.profile)
    assert.equals("/aws/lambda/dwh-dev", found.log_group)
    assert.equals(dir, found.dir)
  end)

  it("stops with the metadata error when nothing is found", function()
    write(fixture .. "/plain/file.py", { "print(1)" })
    vim.cmd.edit(vim.fn.fnameescape(fixture .. "/plain/file.py"))
    local messages = {}
    local real_notify = vim.notify
    vim.notify = function(message)
      table.insert(messages, message)
    end
    local found = resource.require_resource()
    vim.notify = real_notify
    assert.is_nil(found)
    assert.is_truthy(table.concat(messages, "\n"):find("❌ AWS resource metadata not found", 1, true))
  end)

  it("downloads the Lambda and writes .aws-resource.json", function()
    local dir = fixture .. "/lambda/dwh-dev"
    vim.fn.mkdir(dir, "p")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/placeholder.txt"))
    vim.fn.writefile({ "x" }, dir .. "/placeholder.txt")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/placeholder.txt"))

    -- metadata must exist for the action; it describes the function to download
    write(dir .. "/.aws-resource.json", {
      vim.json.encode({ type = "lambda", function_name = "dwh-dev" }),
    })

    local result
    resource.download(nil, function(value)
      result = value
    end)
    assert.is_true(vim.wait(5000, function()
      return result ~= nil
    end))
    assert.is_true(result.ok)

    local meta_path = dir .. "/.aws-resource.json"
    assert.equals(1, vim.fn.filereadable(meta_path))
    local meta = vim.json.decode(table.concat(vim.fn.readfile(meta_path), "\n"))
    assert.equals("lambda", meta.type)
    assert.equals("dwh-dev", meta.function_name)
    assert.equals("/aws/lambda/dwh-dev", meta.log_group)
    assert.equals("ap-northeast-1", meta.region)
    assert.equals(1, vim.fn.filereadable(dir .. "/app.py"))
  end)

  it("creates invoke.json instead of invoking with an empty payload", function()
    local dir = make_resource(fixture .. "/aws-dev/lambda/dwh-dev")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))

    local result
    resource.invoke(nil, function(value)
      result = value
    end)
    assert.is_true(vim.wait(3000, function()
      return result ~= nil
    end))

    assert.is_false(result.ok)
    assert.is_true(result.created)
    assert.equals("{}", table.concat(vim.fn.readfile(dir .. "/invoke.json"), "\n"))
    assert.same({}, vim.fn.readfile(fixture .. "/aws.log"))
    assert.equals("invoke.json", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
  end)

  it("invokes the Lambda with invoke.json and shows StatusCode, FunctionError and ExecutedVersion", function()
    local dir = make_resource(fixture .. "/aws-dev/lambda/dwh-dev")
    write(dir .. "/invoke.json", { '{"order":"42"}' })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))

    local result
    resource.invoke(nil, function(value)
      result = value
    end)
    assert.is_true(vim.wait(5000, function()
      return result ~= nil
    end))

    assert.is_true(result.ok)
    assert.equals(200, result.status)
    assert.equals("$LATEST", result.executed_version)
    assert.equals(dir .. "/response.json", result.response_path)
    assert.equals(dir .. "/invoke.json", result.payload_path)
    assert.is_true(vim.fn.filereadable(dir .. "/response.json") == 1)

    local calls = table.concat(vim.fn.readfile(fixture .. "/aws.log"), "\n")
    assert.is_truthy(calls:find("--profile sbi-dwh-dev", 1, true))
    assert.is_truthy(calls:find("--region ap-northeast-1", 1, true))
    assert.is_truthy(calls:find("lambda invoke --function-name dwh-dev", 1, true))
    assert.is_truthy(calls:find("--cli-binary-format raw-in-base64-out", 1, true))
    assert.is_truthy(calls:find("--payload fileb://", 1, true), calls)
  end)

  it("tails the log group from metadata", function()
    local dir = make_resource(fixture .. "/aws-dev/lambda/dwh-dev", { log_group = "/custom/group" })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))

    local workflow = require("aws.lambda.workflow")
    local original = workflow.tail_logs
    local captured
    workflow.tail_logs = function(opts, name, group)
      captured = { opts = opts, name = name, group = group }
    end
    resource.logs()
    workflow.tail_logs = original

    assert.equals("dwh-dev", captured.name)
    assert.equals("/custom/group", captured.group)
    assert.equals("sbi-dwh-dev", captured.opts.profile)
  end)

  it("falls back to /aws/lambda/<name> when log_group is missing", function()
    local dir = fixture .. "/aws-dev/lambda/dwh-dev"
    write(dir .. "/.aws-resource.json", {
      vim.json.encode({ type = "lambda", function_name = "dwh-dev" }),
    })
    write(dir .. "/handler.py", { "print('hi')" })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))

    local workflow = require("aws.lambda.workflow")
    local original = workflow.tail_logs
    local captured
    workflow.tail_logs = function(_, name, group)
      captured = { name = name, group = group }
    end
    resource.logs()
    workflow.tail_logs = original

    assert.equals("/aws/lambda/dwh-dev", captured.group)
  end)

  it("refreshes the configuration and syncs metadata", function()
    local dir = make_resource(fixture .. "/aws-dev/lambda/dwh-dev")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))

    local result
    resource.refresh(nil, function(value)
      result = value
    end)
    assert.is_true(vim.wait(5000, function()
      return result ~= nil
    end))
    assert.is_true(result.ok)

    local meta = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/.aws-resource.json"), "\n"))
    assert.equals("python3.12", meta.runtime)
    assert.equals("x86_64", meta.architecture)
    assert.equals(512, meta.memory_mb)
    assert.equals(30, meta.timeout_s)
    assert.equals("abc123", meta.code_sha256)
    assert.equals("2026-11-09T04:40:12.000+0000", meta.last_modified)
    assert.same({ "DB_HOST", "STAGE" }, meta.environment_keys)
    -- untouched fields survive the refresh
    assert.equals("123456789012", meta.account)
    assert.equals("/aws/lambda/dwh-dev", meta.log_group)
  end)

  it("shows the metadata file", function()
    local dir = make_resource(fixture .. "/aws-dev/lambda/dwh-dev")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))

    resource.show_metadata()
    local buf = vim.fn.bufnr("aws://resource/result")
    assert.is_true(buf > 0)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find(".aws-resource.json", 1, true))
    assert.is_truthy(text:find("dwh-dev", 1, true))
  end)

  it("refuses unsupported resource types instead of calling AWS", function()
    local dir = fixture .. "/aws-dev/stepfunctions/order-flow"
    write(dir .. "/.aws-resource.json", { vim.json.encode({ type = "stepfunctions", name = "order-flow" }) })
    write(dir .. "/definition.json", { "{}" })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/definition.json"))

    local result
    resource.invoke(nil, function(value)
      result = value
    end)
    assert.is_true(vim.wait(2000, function()
      return result ~= nil
    end))
    assert.is_false(result.ok)
    assert.is_truthy(result.error:find("not implemented", 1, true))
    assert.same({}, vim.fn.readfile(fixture .. "/aws.log"))
  end)
end)
