-- AWS profile parsing, precedence, switching, and the picker.
local profile = require("aws.profile")

local function write_config(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local SAMPLE = {
  "[default]",
  "region = us-east-1",
  "",
  "[profile dev]",
  "role_arn = arn:aws:iam::123456789012:role/PowerUser",
  "source_profile = default",
  "region = ap-northeast-1",
  "",
  "[profile stg]",
  "role_arn = arn:aws:iam::123456789012:role/PowerUser",
  "region = ap-northeast-1",
  "",
  "[profile prod]",
  "role_arn = arn:aws:iam::123456789012:role/PowerUser",
  "region = ap-northeast-1",
  "",
  "[profile sandbox]",
  "source_profile = developer",
  "region = ap-northeast-1",
  "",
  "[sso-session my-sso]",
  "sso_start_url = https://example.awsapps.com/start",
  "",
  "[services default]",
  "s3 =",
  "  max_concurrent_requests = 20",
}

describe("AWS profiles", function()
  local root
  local config_path
  local old_env

  before_each(function()
    root = vim.fn.tempname()
    config_path = root .. "/.aws/config"
    write_config(config_path, SAMPLE)
    old_env = { AWS_CONFIG_FILE = vim.env.AWS_CONFIG_FILE, AWS_PROFILE = vim.env.AWS_PROFILE }
    vim.env.AWS_CONFIG_FILE = config_path
    vim.env.AWS_PROFILE = nil
    profile.reload()
    -- drain scheduled AwsProfileChanged events from the previous example
    vim.wait(30)
  end)

  after_each(function()
    vim.env.AWS_CONFIG_FILE = old_env.AWS_CONFIG_FILE
    vim.env.AWS_PROFILE = old_env.AWS_PROFILE
    vim.fn.delete(root, "rf")
    profile.reload()
  end)

  it("lists default and [profile ...] sections in file order", function()
    assert.same({ "default", "dev", "stg", "prod", "sandbox" }, profile.profiles())
  end)

  it("ignores sso-session and services sections", function()
    assert.is_nil(profile.get("my-sso").region)
    assert.is_nil(profile.get("default").s3)
    assert.equals("us-east-1", profile.get("default").region)
  end)

  it("reads region and role metadata per profile", function()
    assert.equals("ap-northeast-1", profile.region("dev"))
    assert.equals("arn:aws:iam::123456789012:role/PowerUser", profile.get("dev").role_arn)
    assert.equals("default", profile.get("dev").source_profile)
    assert.equals("developer", profile.get("sandbox").source_profile)
  end)

  it("resolves the current profile as env > session state > default", function()
    assert.equals("default", profile.current())
    profile.set("stg")
    vim.wait(50, function()
      return vim.env.AWS_PROFILE == "stg"
    end)
    assert.equals("stg", profile.current())
    vim.env.AWS_PROFILE = "prod"
    assert.equals("prod", profile.current())
    vim.env.AWS_PROFILE = nil
    assert.equals("stg", profile.current())
  end)

  it("set() exports AWS_PROFILE and emits AwsProfileChanged", function()
    local seen = {}
    local group = vim.api.nvim_create_augroup("AwsProfileSpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "AwsProfileChanged",
      callback = function(event)
        table.insert(seen, event.data.profile)
      end,
    })
    assert.equals("dev", profile.set("dev"))
    vim.wait(500, function()
      return #seen > 0
    end)
    assert.same({ "dev" }, seen)
    assert.equals("dev", vim.env.AWS_PROFILE)
    vim.api.nvim_del_augroup_by_id(group)
  end)

  it("rejects an empty profile name", function()
    local name, err = profile.set("  ")
    assert.is_nil(name)
    assert.is_truthy(err)
  end)

  it("summarises profile@region", function()
    assert.equals("dev@ap-northeast-1", profile.summary("dev"))
    vim.fn.writefile({ "[profile bare]" }, config_path)
    profile.reload()
    assert.equals("bare", profile.summary("bare"))
  end)

  it("handles a missing config file without errors", function()
    vim.fn.delete(config_path)
    profile.reload()
    assert.same({}, profile.profiles())
    assert.equals("default", profile.current())
    assert.is_nil(profile.region("dev"))
  end)

  it("keeps the last definition when a profile is duplicated", function()
    write_config(config_path, {
      "[profile dup]",
      "region = us-east-1",
      "",
      "[profile dup]",
      "region = eu-west-1",
      "role_arn = arn:aws:iam::1:role/dup",
    })
    profile.reload()
    assert.same({ "dup" }, profile.profiles())
    assert.equals("eu-west-1", profile.region("dup"))
    assert.equals("arn:aws:iam::1:role/dup", profile.get("dup").role_arn)
  end)

  it("strips inline comments and blank values", function()
    write_config(config_path, {
      "[profile commented]",
      "region = ap-northeast-1  # primary",
      "source_profile =   ",
      "",
    })
    profile.reload()
    assert.equals("ap-northeast-1", profile.region("commented"))
    assert.is_nil(profile.get("commented").source_profile)
  end)

  it("picks a profile through vim.ui.select", function()
    local offered, formatted = {}, {}
    local original = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      offered = vim.deepcopy(items)
      for _, item in ipairs(items) do
        table.insert(formatted, opts.format_item(item))
      end
      on_choice("prod")
    end
    profile.pick()
    vim.ui.select = original

    assert.same({ "default", "dev", "stg", "prod", "sandbox" }, offered)
    assert.is_truthy(table.concat(formatted, "\n"):find("prod  ap%-northeast%-1"))
    vim.wait(200, function()
      return vim.env.AWS_PROFILE == "prod"
    end)
    assert.equals("prod", vim.env.AWS_PROFILE)
  end)

  it("renders the statusline component without an icon and with padding", function()
    vim.env.AWS_PROFILE = "dev"
    profile.reload()
    local component = profile.component()
    assert.equals(" dev@ap-northeast-1 ", component.provider())
    assert.equals(" X dev@ap-northeast-1 ", profile.component({ icon = "X " }).provider())

    vim.fn.delete(config_path)
    profile.reload()
    vim.env.AWS_PROFILE = nil
    assert.equals("", profile.component().provider())
  end)

  it("reports when no profiles exist", function()
    vim.fn.delete(config_path)
    profile.reload()
    local messages = {}
    local original_select, original_notify = vim.ui.select, vim.notify
    vim.ui.select = function()
      error("must not prompt without profiles")
    end
    vim.notify = function(message)
      table.insert(messages, message)
    end
    profile.pick()
    vim.ui.select, vim.notify = original_select, original_notify
    assert.is_truthy(table.concat(messages, "\n"):find("no AWS profiles found", 1, true))
  end)
end)
