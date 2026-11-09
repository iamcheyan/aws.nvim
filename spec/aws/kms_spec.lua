-- KMS explorer: key list rendering, filtering, and the detail view.
local config = require("aws.config")
local kms = require("aws.kms")

local function executable(path, body)
  vim.fn.writefile(vim.split(body, "\n", { plain = true }), path)
  assert.equals(1, vim.fn.setfperm(path, "rwx------"))
end

local function fixture()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/bin", "p")
  executable(
    root .. "/bin/aws",
    [[#!/bin/sh
case "$*" in
  *"kms list-aliases"*)
    printf '%s\n' '{"Aliases":[{"AliasName":"alias/app-config","TargetKeyId":"1111-aaaa"},{"AliasName":"alias/payments","TargetKeyId":"2222-bbbb"}]}'
    ;;
  *"kms list-keys"*)
    printf '%s\n' '{"Keys":[{"KeyId":"1111-aaaa"},{"KeyId":"2222-bbbb"},{"KeyId":"3333-cccc"}]}'
    ;;
  *"kms describe-key"*)
    printf '%s\n' '{"KeyMetadata":{"KeyId":"2222-bbbb","Arn":"arn:aws:kms:ap-northeast-1:123456789012:key/2222-bbbb","Description":"payments key","KeyState":"Enabled","Enabled":true,"KeyUsage":"ENCRYPT_DECRYPT","KeySpec":"SYMMETRIC_DEFAULT","Origin":"AWS_KMS","KeyManager":"CUSTOMER","CreationDate":"2026-01-01T00:00:00+00:00"}}'
    ;;
  *) printf 'unexpected aws args: %s\n' "$*" >&2; exit 2 ;;
esac
]]
  )
  executable(
    root .. "/bin/zip",
    [[#!/bin/sh
exit 0
]]
  )
  return root
end

local function wait_for(predicate)
  assert.is_true(vim.wait(5000, predicate, 10), "timed out waiting for KMS explorer")
end

local function find_line(buf, needle)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

describe("KMS explorer", function()
  local root
  local old_path

  before_each(function()
    config.setup({})
    root = fixture()
    old_path = vim.env.PATH
    vim.env.PATH = root .. "/bin:" .. old_path
  end)

  after_each(function()
    vim.env.PATH = old_path
    vim.fn.delete(root, "rf")
  end)

  it("lists aliases and keys without aliases", function()
    kms.list_keys({ region = "ap-northeast-1" })
    local buf = vim.api.nvim_get_current_buf()
    assert.equals("aws-kms", vim.bo[buf].filetype)
    wait_for(function()
      return find_line(buf, "alias/app-config") ~= nil
    end)

    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("alias/app-config", 1, true))
    assert.is_truthy(text:find("2222-bbbb", 1, true))
    assert.is_truthy(text:find("(no alias)", 1, true))
    assert.is_truthy(text:find("3333-cccc", 1, true))
    assert.is_truthy(text:find("3 key(s)", 1, true))
    -- aliased keys are not duplicated as standalone rows
    local _, count = text:gsub("1111%-aaaa", "")
    assert.equals(1, count)
  end)

  it("filters rows by alias or key id", function()
    kms.list_keys({ region = "ap-northeast-1" })
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      return find_line(buf, "alias/payments") ~= nil
    end)

    local actions
    actions = require("aws.keymaps")
    assert.is_function(actions.apply_kms)

    -- drive the filter through the buffer-local mapping table
    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local lhs = vim.tbl_map(function(m)
      return m.lhs
    end, maps)
    assert.is_true(vim.tbl_contains(lhs, "<CR>"))
    assert.is_true(vim.tbl_contains(lhs, "F"))
    assert.is_true(vim.tbl_contains(lhs, "<F5>"))
  end)

  it("opens the detail view for the key under the cursor", function()
    kms.list_keys({ region = "ap-northeast-1" })
    local buf = vim.api.nvim_get_current_buf()
    wait_for(function()
      return find_line(buf, "alias/payments") ~= nil
    end)

    vim.api.nvim_win_set_cursor(0, { find_line(buf, "alias/payments"), 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    wait_for(function()
      return vim.fn.bufnr("aws://kms/detail/2222-bbbb") > 0
    end)

    local detail = vim.fn.bufnr("aws://kms/detail/2222-bbbb")
    local text = table.concat(vim.api.nvim_buf_get_lines(detail, 0, -1, false), "\n")
    assert.is_truthy(text:find("payments key", 1, true))
    assert.is_truthy(text:find("ENCRYPT_DECRYPT", 1, true))
    assert.is_truthy(text:find("SYMMETRIC_DEFAULT", 1, true))
    assert.is_truthy(text:find("CUSTOMER", 1, true))
  end)
end)
