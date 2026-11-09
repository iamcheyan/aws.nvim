-- Resource discovery and upload: metadata lookup, packaging, and AWS CLI calls.
local upload = require("aws.upload")

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
  vim.fn.writefile({}, root .. "/zip.log")

  executable(
    root .. "/bin/aws",
    [[#!/bin/sh
printf '%s\n' "$*" >> "$AWS_FAKE_LOG"
case "$*" in
  *"lambda update-function-code"*)
    [ "$AWS_FAKE_SLOW" = "1" ] && sleep 1
    if [ "$AWS_FAKE_FAIL" = "1" ]; then
      printf 'AccessDeniedException: User is not authorized to perform: lambda:UpdateFunctionCode\n' >&2
      exit 254
    fi
    printf '%s\n' '{"FunctionName":"dwh-dev","LastModified":"2026-11-09T04:00:00.000+0000","CodeSize":512}'
    ;;
  *) printf 'unexpected aws args: %s\n' "$*" >&2; exit 2 ;;
esac
]]
  )

  executable(
    root .. "/bin/zip",
    [[#!/bin/sh
printf '%s\n' "$*" >> "$AWS_FAKE_ZIP_LOG"
out=""
for arg in "$@"; do
  case "$arg" in
    *.zip) out="$arg" ;;
  esac
done
printf '%s\n' 'fake archive' > "$out"
]]
  )

  return root
end

describe("AWS resource upload", function()
  local fixture
  local old_path
  local old_cwd
  local old_log
  local old_zip_log

  before_each(function()
    fixture = make_fixture()
    old_path, old_cwd = vim.env.PATH, vim.fn.getcwd()
    old_log, old_zip_log = vim.env.AWS_FAKE_LOG, vim.env.AWS_FAKE_ZIP_LOG
    vim.env.PATH = fixture .. "/bin:" .. old_path
    vim.env.AWS_FAKE_LOG = fixture .. "/aws.log"
    vim.env.AWS_FAKE_ZIP_LOG = fixture .. "/zip.log"
    vim.env.AWS_FAKE_FAIL = nil
    vim.env.AWS_FAKE_SLOW = nil
    vim.cmd.cd(fixture)
  end)

  after_each(function()
    vim.env.PATH = old_path
    vim.env.AWS_FAKE_LOG = old_log
    vim.env.AWS_FAKE_ZIP_LOG = old_zip_log
    vim.env.AWS_FAKE_FAIL = nil
    vim.env.AWS_FAKE_SLOW = nil
    vim.cmd.cd(old_cwd)
    vim.fn.delete(fixture, "rf")
    upload.last_result = nil
  end)

  it("reads .aws-resource.json from a parent directory", function()
    local dir = fixture .. "/aws-dev/lambda/dwh-dev"
    write(dir .. "/.aws-resource.json", {
      vim.json.encode({
        type = "lambda",
        function_name = "dwh-dev",
        region = "ap-northeast-1",
        profile = "sbi-dwh-dev",
      }),
    })
    write(dir .. "/src/app.py", { "print('hi')" })

    local resource, err = upload.discover(dir .. "/src/app.py")
    assert.is_nil(err)
    assert.equals("lambda", resource.type)
    assert.equals("dwh-dev", resource.name)
    assert.equals("ap-northeast-1", resource.region)
    assert.equals("sbi-dwh-dev", resource.profile)
    assert.equals(dir, resource.dir)
    assert.equals("resource", resource.source)
  end)

  it("prefers .aws-resource.json over the directory layout and legacy metadata", function()
    local dir = fixture .. "/aws-dev/lambda/dwh-dev"
    write(dir .. "/.aws-meta.json", { vim.json.encode({ function_name = "legacy-name" }) })
    write(dir .. "/.aws-resource.json", { vim.json.encode({ type = "lambda", function_name = "custom-fn" }) })
    write(dir .. "/handler.py", { "print('hi')" })

    local resource = upload.discover(dir .. "/handler.py")
    assert.equals("custom-fn", resource.name)
    assert.equals("resource", resource.source)
  end)

  it("falls back to legacy .aws-meta.json bindings", function()
    local dir = fixture .. "/lambda/payments-api"
    write(dir .. "/.aws-meta.json", {
      vim.json.encode({ function_name = "payments-api", region = "ap-northeast-1" }),
    })
    write(dir .. "/handler.py", { "print('hi')" })

    local resource = upload.discover(dir .. "/handler.py")
    assert.equals("lambda", resource.type)
    assert.equals("payments-api", resource.name)
    assert.equals("meta", resource.source)
  end)

  it("infers the resource type from lambda/, stepfunctions/ and glue/ directories", function()
    write(fixture .. "/ws/lambda/orders-worker/app.py", { "print(1)" })
    local lambda = upload.discover(fixture .. "/ws/lambda/orders-worker/app.py")
    assert.equals("lambda", lambda.type)
    assert.equals("orders-worker", lambda.name)
    assert.equals("layout", lambda.source)

    write(fixture .. "/ws/stepfunctions/order-flow/definition.json", { "{}" })
    local sfn = upload.discover(fixture .. "/ws/stepfunctions/order-flow/definition.json")
    assert.equals("stepfunctions", sfn.type)
    assert.equals("order-flow", sfn.name)

    write(fixture .. "/ws/glue/etl-job/script.py", { "print(2)" })
    local glue = upload.discover(fixture .. "/ws/glue/etl-job/script.py")
    assert.equals("glue", glue.type)
    assert.equals("etl-job", glue.name)
  end)

  it("reports a clear error when nothing identifies the resource", function()
    write(fixture .. "/plain/file.py", { "print(1)" })
    local resource, err = upload.discover(fixture .. "/plain/file.py")
    assert.is_nil(resource)
    assert.is_truthy(err:find("no .aws-resource.json", 1, true))
  end)

  it("infers a Lambda from the AWS Explorer selection as a last resort", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "aws://lambda/functions/ap-northeast-1")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "Name             Runtime       Memory  Code size",
      "dwh-dev          python3.12    256 MB  4.1 KB",
    })
    vim.bo[buf].filetype = "aws-lambda"
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local resource = upload.discover()
    assert.equals("lambda", resource.type)
    assert.equals("dwh-dev", resource.name)
    assert.equals("ap-northeast-1", resource.region)
    assert.equals("explorer", resource.source)
  end)

  it("saves modified buffers, packages with exclusions, and uploads the Lambda", function()
    local dir = fixture .. "/aws-dev/lambda/dwh-dev"
    write(dir .. "/.aws-resource.json", {
      vim.json.encode({
        type = "lambda",
        function_name = "dwh-dev",
        region = "ap-northeast-1",
        profile = "sbi-dwh-dev",
      }),
    })
    write(dir .. "/handler.py", { "print('before')" })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "print('after')" })
    assert.is_true(vim.bo.modified)

    local result
    upload.upload(nil, function(value)
      result = value
    end)
    assert.is_true(vim.wait(5000, function()
      return result ~= nil
    end))

    assert.is_true(result.ok)
    assert.equals("Upload Success", result.title)
    assert.same({ "print('after')" }, vim.fn.readfile(dir .. "/handler.py"))

    local zip_call = table.concat(vim.fn.readfile(fixture .. "/zip.log"), "\n")
    assert.is_truthy(zip_call:find("function.zip", 1, true))
    for _, pattern in ipairs({ ".git", "__pycache__", ".pytest_cache", ".venv", "node_modules", "*.pyc" }) do
      assert.is_truthy(zip_call:find(pattern, 1, true), "zip should exclude " .. pattern)
    end

    local aws_call = table.concat(vim.fn.readfile(fixture .. "/aws.log"), "\n")
    assert.is_truthy(aws_call:find("--profile sbi-dwh-dev", 1, true))
    assert.is_truthy(aws_call:find("--region ap-northeast-1", 1, true))
    assert.is_truthy(aws_call:find("lambda update%-function%-code", 1, false))
    assert.is_truthy(aws_call:find("--function-name dwh-dev", 1, true))
    assert.is_truthy(aws_call:find("fileb://" .. dir .. "/function.zip", 1, true))
  end)

  it("shows the pre-upload banner only while the upload is running", function()
    local dir = fixture .. "/aws-dev/lambda/dwh-dev"
    write(dir .. "/.aws-resource.json", {
      vim.json.encode({ type = "lambda", function_name = "dwh-dev", profile = "sbi-dwh-dev" }),
    })
    write(dir .. "/handler.py", { "print('hi')" })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))
    vim.env.AWS_FAKE_SLOW = "1"

    local result
    upload.upload(nil, function(value)
      result = value
    end)
    assert.is_true(
      vim.wait(3000, function()
        return upload.banner_open()
      end),
      "banner should be visible during the upload"
    )
    assert.is_true(vim.wait(6000, function()
      return result ~= nil
    end))
    assert.is_false(upload.banner_open(), "banner should close when the upload finishes")
  end)

  it("surfaces raw AWS CLI errors instead of hiding them", function()
    local dir = fixture .. "/aws-dev/lambda/dwh-dev"
    write(dir .. "/.aws-resource.json", { vim.json.encode({ type = "lambda", function_name = "dwh-dev" }) })
    write(dir .. "/handler.py", { "print('hi')" })
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/handler.py"))
    vim.env.AWS_FAKE_FAIL = "1"

    local result
    upload.upload(nil, function(value)
      result = value
    end)
    assert.is_true(vim.wait(5000, function()
      return result ~= nil
    end))

    assert.is_false(result.ok)
    assert.is_truthy(result.error:find("AccessDeniedException", 1, true))
  end)

  it("refuses Step Functions and Glue uploads without touching AWS", function()
    write(fixture .. "/ws/stepfunctions/order-flow/definition.json", { "{}" })
    vim.cmd.edit(vim.fn.fnameescape(fixture .. "/ws/stepfunctions/order-flow/definition.json"))

    local result
    upload.upload(nil, function(value)
      result = value
    end)
    assert.is_true(vim.wait(2000, function()
      return result ~= nil
    end))

    assert.is_false(result.ok)
    assert.is_truthy(result.error:find("not implemented", 1, true))
    assert.same({}, vim.fn.readfile(fixture .. "/aws.log"))
    assert.same({}, vim.fn.readfile(fixture .. "/zip.log"))
  end)
end)
