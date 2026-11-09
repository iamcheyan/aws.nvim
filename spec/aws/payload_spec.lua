-- invoke.json payload workflow: create, edit, invoke, view response, upload+invoke.
local config = require("aws.config")
local workflow = require("aws.lambda.workflow")

local function executable(path, body)
  vim.fn.writefile(vim.split(body, "\n", { plain = true }), path)
  assert.equals(1, vim.fn.setfperm(path, "rwx------"))
end

local function wait_for(predicate)
  assert.is_true(vim.wait(10000, predicate, 10), "timed out waiting for the payload workflow")
end

local function fixture()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/bin", "p")
  vim.fn.writefile({}, root .. "/aws.log")
  vim.fn.writefile({ "print('hello')" }, root .. "/source.py")
  executable(
    root .. "/bin/aws",
    [[#!/bin/sh
printf '%s\n' "$*" >> "$AWS_FAKE_LOG"
case "$*" in
  *"lambda get-function "*) printf '%s\n' '{"Code":{"Location":"https://example.invalid/archive"}}' ;;
  *"lambda invoke"*)
    for out in "$@"; do case "$out" in */response.json) target="$out" ;; esac; done
    printf '%s\n' '{"statusCode":200,"body":"ok"}' > "$target"
    printf '%s\n' '{"StatusCode":200,"ExecutedVersion":"$LATEST"}'
    ;;
  *"lambda update-function-code"*) printf '%s\n' '{"FunctionName":"payments-api"}' ;;
  *"sts get-caller-identity"*) printf '%s\n' '123456789012' ;;
  *"configure get region"*) printf '%s\n' 'ap-northeast-1' ;;
  *) printf 'unexpected aws args: %s\n' "$*" >&2; exit 2 ;;
esac
]]
  )
  executable(
    root .. "/bin/curl",
    [[#!/bin/sh
while [ "$#" -gt 0 ]; do if [ "$1" = "--output" ]; then shift; out="$1"; fi; shift; done
printf 'zipdata' > "$out"
]]
  )
  executable(
    root .. "/bin/unzip",
    [[#!/bin/sh
if [ "$1" = "-Z1" ]; then printf 'app.py\n'; exit 0; fi
while [ "$#" -gt 0 ]; do if [ "$1" = "-d" ]; then shift; dest="$1"; fi; shift; done
mkdir -p "$dest"
printf "print('hi')\n" > "$dest/app.py"
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

local function bind(root, name)
  local dir = root .. "/lambda/" .. name
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(
    { vim.json.encode({ function_name = name, region = "ap-northeast-1", account = "123456789012" }) },
    dir .. "/.aws-meta.json"
  )
  vim.fn.writefile({ "print('hi')" }, dir .. "/app.py")
  return dir
end

describe("invoke payload workflow", function()
  local root
  local old_env

  before_each(function()
    config.setup({})
    root = fixture()
    old_env = { PATH = vim.env.PATH, AWS_FAKE_LOG = vim.env.AWS_FAKE_LOG, cwd = vim.fn.getcwd() }
    vim.env.PATH = root .. "/bin:" .. old_env.PATH
    vim.env.AWS_FAKE_LOG = root .. "/aws.log"
    vim.cmd.cd(root)
  end)

  after_each(function()
    vim.env.PATH = old_env.PATH
    vim.env.AWS_FAKE_LOG = old_env.AWS_FAKE_LOG
    vim.cmd.cd(old_env.cwd)
    vim.fn.delete(root, "rf")
  end)

  it("creates invoke.json with {} when a Lambda is downloaded", function()
    local dir = root .. "/lambda/payments-api"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(
      { vim.json.encode({ type = "lambda", function_name = "payments-api" }) },
      dir .. "/.aws-resource.json"
    )

    local done
    workflow.download_source("payments-api", nil, function()
      done = true
    end)
    wait_for(function()
      return done == true
    end)

    assert.equals(1, vim.fn.filereadable(dir .. "/invoke.json"))
    assert.equals("{}", table.concat(vim.fn.readfile(dir .. "/invoke.json"), "\n"))
  end)

  it("opens invoke.json, creating it first when missing", function()
    local dir = bind(root, "payments-api")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/app.py"))

    workflow.edit_payload("payments-api")
    assert.equals(dir .. "/invoke.json", vim.api.nvim_buf_get_name(0))
    assert.equals("{}", table.concat(vim.fn.readfile(dir .. "/invoke.json"), "\n"))

    -- existing payloads are opened untouched
    vim.fn.writefile({ '{"order":"7"}' }, dir .. "/invoke.json")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/app.py"))
    workflow.edit_payload("payments-api")
    assert.equals('{"order":"7"}', table.concat(vim.fn.readfile(dir .. "/invoke.json"), "\n"))
  end)

  it("invokes with fileb://invoke.json and writes response.json", function()
    local dir = bind(root, "payments-api")
    vim.fn.writefile({ '{"order":"42"}' }, dir .. "/invoke.json")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/app.py"))

    local result
    workflow.invoke_function("payments-api", nil, function(value)
      result = value
    end)
    wait_for(function()
      return result ~= nil
    end)

    assert.is_true(result.ok)
    assert.equals(200, result.status)
    assert.equals(dir .. "/invoke.json", result.payload_path)
    assert.equals(dir .. "/response.json", result.response_path)

    local calls = table.concat(vim.fn.readfile(root .. "/aws.log"), "\n")
    assert.is_truthy(calls:find("--payload fileb://" .. dir .. "/invoke.json", 1, true))
    assert.is_truthy(vim.fn.filereadable(dir .. "/response.json") == 1)
  end)

  it("creates invoke.json instead of invoking when the payload file is missing", function()
    local dir = bind(root, "payments-api")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/app.py"))

    local meta, binding_dir = workflow.find_binding("payments-api")
    assert.is_truthy(meta)
    local result
    workflow.invoke_file(binding_dir, "payments-api", nil, function(value)
      result = value
    end)
    wait_for(function()
      return result ~= nil
    end)

    assert.is_false(result.ok)
    assert.is_true(result.created)
    assert.equals("{}", table.concat(vim.fn.readfile(dir .. "/invoke.json"), "\n"))
    assert.equals("invoke.json", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    assert.same({}, vim.fn.readfile(root .. "/aws.log"))
  end)

  it("refuses invalid JSON without calling AWS", function()
    local dir = bind(root, "payments-api")
    vim.fn.writefile({ "{ not json" }, dir .. "/invoke.json")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/app.py"))

    local result
    workflow.invoke_function("payments-api", nil, function(value)
      result = value
    end)
    wait_for(function()
      return result ~= nil
    end)

    assert.is_false(result.ok)
    assert.is_truthy(result.error:find("not valid JSON", 1, true))
    assert.same({}, vim.fn.readfile(root .. "/aws.log"))
  end)

  it("opens response.json with v and reports a missing response", function()
    local dir = bind(root, "payments-api")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/app.py"))

    local messages = {}
    local real_notify = vim.notify
    vim.notify = function(message)
      table.insert(messages, message)
    end
    workflow.view_response("payments-api")
    vim.wait(1000, function()
      return #messages > 0
    end, 10)
    vim.notify = real_notify
    assert.is_truthy(table.concat(messages, "\n"):find("no response.json yet", 1, true))

    vim.fn.writefile({ '{"statusCode":200}' }, dir .. "/response.json")
    workflow.view_response("payments-api")
    assert.equals(dir .. "/response.json", vim.api.nvim_buf_get_name(0))
  end)

  it("uploads and then invokes with invoke.json", function()
    local dir = bind(root, "payments-api")
    vim.fn.writefile({ '{"order":"42"}' }, dir .. "/invoke.json")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/app.py"))

    local result
    workflow.upload_and_invoke_function("payments-api", nil, function(value)
      result = value
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.is_true(result.ok)

    local order = {}
    for line in io.lines(root .. "/aws.log") do
      if line:find("lambda update%-function%-code", 1, false) then
        table.insert(order, "update")
      elseif line:find("lambda invoke", 1, true) then
        table.insert(order, "invoke")
      end
    end
    assert.same({ "update", "invoke" }, order)
  end)
end)
