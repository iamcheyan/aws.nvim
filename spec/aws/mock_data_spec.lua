-- End-to-end checks against the committed mock AWS CLI (docs/mock-data).
-- These tests never touch a real AWS account or the network.
local config = require("aws.config")

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h:h:h")
end

local ROOT = repo_root()
local BIN = ROOT .. "/docs/mock-data/bin"
local AWS_CONFIG = ROOT .. "/docs/mock-data/aws-config"

local function wait_for(predicate)
  assert.is_true(vim.wait(10000, predicate, 10), "timed out waiting for the mock workflow")
end

local function find_line(buf, needle)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

describe("mock AWS data", function()
  local workspace
  local old_env

  before_each(function()
    config.setup({})
    workspace = vim.fn.tempname()
    vim.fn.mkdir(workspace .. "/lambda/dwh-dev", "p")
    vim.fn.writefile({ "print('mock')" }, workspace .. "/lambda/dwh-dev/handler.py")
    vim.fn.writefile({ '{"order":"42"}' }, workspace .. "/lambda/dwh-dev/invoke.json")
    vim.fn.writefile(
      { vim.json.encode({ function_name = "dwh-dev", region = "ap-northeast-1", account = "123456789012" }) },
      workspace .. "/lambda/dwh-dev/.aws-meta.json"
    )
    vim.fn.writefile({}, workspace .. "/aws.log")

    old_env = {}
    for _, key in ipairs({ "PATH", "AWS_CONFIG_FILE", "AWS_PROFILE", "AWS_FAKE_LOG", "AWS_FAKE_SOURCE" }) do
      old_env[key] = vim.env[key]
    end
    vim.env.PATH = BIN .. ":" .. old_env.PATH
    vim.env.AWS_CONFIG_FILE = AWS_CONFIG
    vim.env.AWS_PROFILE = "dev"
    vim.env.AWS_FAKE_LOG = workspace .. "/aws.log"
    vim.env.AWS_FAKE_SOURCE = nil
    require("aws.profile").reload()
    vim.cmd.cd(workspace)
  end)

  after_each(function()
    for key, value in pairs(old_env) do
      vim.env[key] = value
    end
    vim.cmd.cd(ROOT)
    vim.fn.delete(workspace, "rf")
    require("aws.profile").reload()
    pcall(function()
      require("aws.lambda.workflow").stop_logs()
    end)
  end)

  it("parses the committed aws-config fixture", function()
    local profile = require("aws.profile")
    assert.same({ "default", "dev", "stg", "prod", "sandbox", "no-region" }, profile.profiles())
    assert.equals("ap-northeast-1", profile.region("dev"))
    assert.equals("us-east-1", profile.region("default"))
    assert.is_nil(profile.region("no-region"))
    assert.equals("no-region", profile.summary("no-region"))
    -- sso-session must not become a profile
    assert.is_false(vim.tbl_contains(profile.profiles(), "corp"))
  end)

  it("lists mock Lambda functions with the mock CLI", function()
    require("aws.lambda.functions").open()
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      return find_line(buf, "dwh-dev") ~= nil
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("payments-api", 1, true))
    assert.is_truthy(text:find("python3.12", 1, true))
  end)

  it("downloads a Lambda through the mock curl/unzip chain", function()
    local workflow = require("aws.lambda.workflow")
    local done
    workflow.download_source("dwh-dev", nil, function()
      done = true
    end)
    wait_for(function()
      return done == true
    end)

    local dir = workspace .. "/lambda/dwh-dev"
    assert.equals(1, vim.fn.filereadable(dir .. "/app.py"))
    assert.equals(1, vim.fn.filereadable(dir .. "/invoke.json"))
    local meta = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/.aws-resource.json"), "\n"))
    assert.equals("lambda", meta.type)
    assert.equals("/aws/lambda/dwh-dev", meta.log_group)
  end)

  it("invokes and uploads through the mock CLI, logging the profile", function()
    local workflow = require("aws.lambda.workflow")
    local result
    workflow.invoke_function("dwh-dev", nil, function(value)
      result = value
    end)
    wait_for(function()
      return result ~= nil
    end)
    assert.is_true(result.ok)
    assert.equals(200, result.status)

    local response = table.concat(vim.fn.readfile(workspace .. "/lambda/dwh-dev/response.json"), "\n")
    assert.is_truthy(response:find('"profile":"dev"', 1, true))

    local uploaded
    workflow.upload_and_invoke_function("dwh-dev", nil, function(value)
      uploaded = value
    end)
    wait_for(function()
      return uploaded ~= nil
    end)
    assert.is_true(uploaded.ok)

    local calls = table.concat(vim.fn.readfile(workspace .. "/aws.log"), "\n")
    assert.is_truthy(calls:find("lambda invoke", 1, true))
    assert.is_truthy(calls:find("lambda update%-function%-code", 1, false))
    for _, line in ipairs(vim.fn.readfile(workspace .. "/aws.log")) do
      assert.is_truthy(line:match("^dev "), "every mock call should run as the dev profile: " .. line)
    end
  end)

  it("renders the mock KMS key list", function()
    require("aws.kms").list_keys()
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      return find_line(buf, "alias/payments") ~= nil
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("(no alias)", 1, true))
    assert.is_truthy(text:find("3 key(s)", 1, true))
  end)
end)
