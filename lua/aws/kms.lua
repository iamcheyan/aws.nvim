--- aws.nvim – KMS key explorer (aliases + keys, detail view).
local M = {}

local spawn = require("aws.spawn")
local buf_mod = require("aws.buffer")
local keymaps = require("aws.keymaps")

local FILETYPE = "aws-kms"
local ALIAS_WIDTH = 44

local _state = {}

local function identity(call_opts)
  local config = require("aws.config")
  local profile = (call_opts and call_opts.profile) or config.values.default_aws_profile
  local region = (call_opts and call_opts.region)
    or config.values.default_aws_region
    or vim.env.AWS_DEFAULT_REGION
    or vim.env.AWS_REGION
    or "default"
  return table.concat({ profile or "default", region }, "@"), region, profile
end

local function buf_name(id)
  return "aws://kms/keys/" .. id
end

local function pad_right(s, width)
  if #s >= width then
    return s
  end
  return s .. string.rep(" ", width - #s)
end

local function render(buf, st)
  local lines = { "" }
  table.insert(lines, string.rep("-", ALIAS_WIDTH + 2 + #"Key ID"))
  table.insert(lines, pad_right("Alias", ALIAS_WIDTH) .. "  Key ID")
  local line_map = {}
  local filter = st.filter ~= "" and st.filter:lower() or nil
  local count = 0
  for _, entry in ipairs(st.entries) do
    local label = entry.alias or "(no alias)"
    local haystack = (label .. " " .. entry.key_id):lower()
    if not filter or haystack:find(filter, 1, true) then
      table.insert(lines, pad_right(label, ALIAS_WIDTH) .. "  " .. entry.key_id)
      line_map[#lines] = entry.key_id
      count = count + 1
    end
  end
  if count == 0 then
    table.insert(lines, "  (no keys)")
  end
  table.insert(lines, "")
  table.insert(lines, string.format("  %d key(s)", count))
  buf_mod.set_lines(buf, lines)
  st.line_map = line_map
end

local function open_detail(key_id, call_opts)
  spawn.run({ "kms", "describe-key", "--key-id", key_id, "--output", "json" }, function(ok, lines)
    if not ok then
      require("aws.lambda.workflow").show_text(
        "KMS key: " .. key_id,
        vim.split(table.concat(lines, "\n"), "\n", { plain = true }),
        "aws://kms/detail/" .. key_id
      )
      return
    end
    local ok_json, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    local meta = ok_json and type(data) == "table" and data.KeyMetadata or nil
    if not meta then
      require("aws.lambda.workflow").show_text(
        "KMS key: " .. key_id,
        { "could not parse describe-key output" },
        "aws://kms/detail/" .. key_id
      )
      return
    end
    require("aws.lambda.workflow").show_text("KMS key: " .. key_id, {
      "KeyId:       " .. tostring(meta.KeyId),
      "Arn:         " .. tostring(meta.Arn),
      "Description: " .. tostring(meta.Description or "-"),
      "State:       " .. tostring(meta.KeyState),
      "Enabled:     " .. tostring(meta.Enabled),
      "Usage:       " .. tostring(meta.KeyUsage),
      "Spec:        " .. tostring(meta.KeySpec),
      "Origin:      " .. tostring(meta.Origin),
      "Manager:     " .. tostring(meta.KeyManager),
      "Created:     " .. tostring(meta.CreationDate),
    }, "aws://kms/detail/" .. key_id)
  end, call_opts)
end

local function fetch(st, buf, call_opts)
  st.entries = {}
  local seen = {}
  local pending = 2
  local failed = false

  local function maybe_render()
    pending = pending - 1
    if pending == 0 and not failed then
      render(buf, st)
    end
  end

  spawn.run({ "kms", "list-aliases", "--output", "json" }, function(ok, lines)
    if not ok then
      failed = true
      buf_mod.set_error(buf, lines)
      return
    end
    local ok_json, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    local aliases = ok_json and type(data) == "table" and data.Aliases or {}
    for _, alias in ipairs(aliases) do
      if type(alias) == "table" and type(alias.TargetKeyId) == "string" then
        seen[alias.TargetKeyId] = true
        table.insert(st.entries, { alias = alias.AliasName, key_id = alias.TargetKeyId })
      end
    end
    maybe_render()
  end, call_opts)

  spawn.run({ "kms", "list-keys", "--output", "json" }, function(ok, lines)
    if not ok then
      failed = true
      buf_mod.set_error(buf, lines)
      return
    end
    local ok_json, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    local keys = ok_json and type(data) == "table" and data.Keys or {}
    for _, key in ipairs(keys) do
      if type(key) == "table" and type(key.KeyId) == "string" and not seen[key.KeyId] then
        table.insert(st.entries, { alias = nil, key_id = key.KeyId })
      end
    end
    maybe_render()
  end, call_opts)
end

--- Open the KMS key list in a horizontal split.
---@param call_opts AwsCallOpts|nil
function M.list_keys(call_opts)
  local id, region, profile = identity(call_opts)
  local buf = buf_mod.get_or_create(buf_name(id), FILETYPE)
  local st = _state[id]
  if not st then
    st = { entries = {}, filter = "", line_map = {}, region = region, profile = profile }
    _state[id] = st
  end
  buf_mod.set_loading(buf)
  buf_mod.open_split(buf)

  keymaps.apply_kms(buf, {
    open_detail = function()
      local key_id = st.line_map[vim.api.nvim_win_get_cursor(0)[1]]
      if key_id then
        open_detail(key_id, call_opts)
      end
    end,
    filter = function()
      vim.ui.input({ prompt = "Filter KMS keys: ", default = st.filter }, function(value)
        if value == nil then
          return
        end
        st.filter = value
        render(buf, st)
      end)
    end,
    clear_filter = function()
      st.filter = ""
      render(buf, st)
    end,
    refresh = function()
      buf_mod.set_loading(buf)
      fetch(st, buf, call_opts)
    end,
    close = function()
      pcall(vim.cmd, "close")
    end,
  })

  fetch(st, buf, call_opts)
end

return M
