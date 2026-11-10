--- aws.nvim – AWS profile discovery and switching.
--- Reads ~/.aws/config (or $AWS_CONFIG_FILE), exposes the profile list and the
--- current profile, and switches profiles by setting AWS_PROFILE.
local M = {}

local state = { profile = nil }

local cache = { path = nil, mtime = nil, size = nil, data = nil }

--- Path of the AWS CLI config file.
---@return string
function M.config_path()
  local explicit = vim.env.AWS_CONFIG_FILE
  if type(explicit) == "string" and explicit ~= "" then
    return explicit
  end
  local home = vim.env.HOME or vim.fn.expand("~")
  return home .. "/.aws/config"
end

--- Strip an inline comment, but keep `#` inside values that have no space before it.
---@param value string
---@return string
local function strip_comment(value)
  return (value:gsub("%s+[#;].*$", ""))
end

--- Parse the INI body of ~/.aws/config.
--- Supports `[default]`, `[profile name]`, ignores `[sso-session]`, `[services]`
--- and any other non-profile section. Duplicate profiles merge with last-wins.
---@param text string
---@return table { order = string[], profiles = table<string, table> }
function M.parse(text)
  local order, profiles = {}, {}
  local current = nil
  local lines = vim.split(text or "", "\n", { plain = true })
  for index, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    line = vim.trim((line:gsub("^\239\187\191", "")))
    local is_comment = line == "" or line:match("^[#;]") ~= nil
    if not is_comment then
      local section = line:match("^%[(.-)%]$")
      if section then
        local name = section:match("^[Pp][Rr][Oo][Ff][Ii][Ll][Ee]%s+(.+)$")
        if not name and section:lower() == "default" then
          name = "default"
        end
        if name then
          name = vim.trim(name)
          current = profiles[name]
          if not current then
            current = {}
            profiles[name] = current
            table.insert(order, name)
          end
        else
          -- sso-session, services and other sections are not profiles
          current = nil
        end
      elseif current then
        local key, value = line:match("^([^=]+)=(.*)$")
        if key then
          key = vim.trim(key):lower()
          value = strip_comment(vim.trim(value))
          if value ~= "" then
            current[key] = value
          end
        end
      end
    end
  end
  return { order = order, profiles = profiles }
end

--- Load and cache the parsed config; reloads when the file changes.
---@return table data, string path, boolean exists
function M.load()
  local path = M.config_path()
  local stat = vim.uv.fs_stat(path)
  if not stat then
    cache = { path = path, mtime = nil, size = nil, data = { order = {}, profiles = {} } }
    return cache.data, path, false
  end
  if cache.path == path and cache.data and cache.mtime == stat.mtime.sec and cache.size == stat.size then
    return cache.data, path, true
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  local data = ok and M.parse(table.concat(lines, "\n")) or { order = {}, profiles = {} }
  cache = { path = path, mtime = stat.mtime.sec, size = stat.size, data = data }
  return data, path, true
end

--- Drop the cache so the next call re-reads the file.
function M.reload()
  cache = { path = nil, mtime = nil, size = nil, data = nil }
  state.profile = nil
  return M.profiles()
end

--- All profile names in file order (`default` first when present).
---@return string[]
function M.profiles()
  local data = M.load()
  return vim.deepcopy(data.order)
end

--- Metadata for one profile.
---@param name string|nil defaults to the current profile
---@return table
function M.get(name)
  local data = M.load()
  return data.profiles[name or M.current()] or {}
end

--- Current profile: $AWS_PROFILE, then the profile chosen in this session, then default.
---@return string
function M.current()
  local env = vim.env.AWS_PROFILE
  if type(env) == "string" and env ~= "" then
    return env
  end
  if type(state.profile) == "string" and state.profile ~= "" then
    return state.profile
  end
  return "default"
end

--- Region configured for a profile, if any.
---@param name string|nil
---@return string|nil
function M.region(name)
  local entry = M.get(name)
  local region = entry.region
  if type(region) == "string" and region ~= "" then
    return region
  end
  return nil
end

--- "profile@region" or "profile" when no region is configured.
---@param name string|nil
---@return string
function M.summary(name)
  local profile = name or M.current()
  local region = M.region(profile)
  if region then
    return profile .. "@" .. region
  end
  return profile
end

--- Switch the active profile: sets $AWS_PROFILE, remembers it, and notifies listeners.
---@param name string
---@return string|nil profile, string|nil error
function M.set(name)
  if type(name) ~= "string" or vim.trim(name) == "" then
    return nil, "invalid profile name"
  end
  local profile = vim.trim(name)
  state.profile = profile
  vim.env.AWS_PROFILE = profile
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "AwsProfileChanged",
      data = { profile = profile },
    })
    pcall(vim.cmd, "redrawstatus!")
  end)
  return profile
end

--- Prompt for a profile with vim.ui.select (dressing/snacks/telescope aware).
---@param opts table|nil { prompt = string }
function M.pick(opts)
  opts = opts or {}
  local items = M.profiles()
  if #items == 0 then
    vim.notify("aws.nvim: no AWS profiles found in " .. M.config_path(), vim.log.levels.WARN)
    return
  end
  local current = M.current()
  vim.ui.select(items, {
    prompt = opts.prompt or "AWS profile",
    format_item = function(item)
      local region = M.region(item)
      local suffix = region and ("  " .. region) or "  (no region)"
      if item == current then
        suffix = suffix .. "  • current"
      end
      return item .. suffix
    end,
  }, function(choice)
    if choice then
      M.set(choice)
    end
  end)
end

--- Optional Heirline component. The statusline refresh is driven by the
--- AwsProfileChanged autocmd, so the caller only has to mount the component.
---@param opts table|nil { icon = string, hl = string }
---@return table
function M.component(opts)
  opts = opts or {}
  return {
    provider = function()
      return (opts.icon or "󰸏 ") .. M.summary()
    end,
    hl = opts.hl or "DiagnosticInfo",
    on_click = {
      name = "aws_profile_menu",
      callback = function(_, _, _, button)
        if button ~= "l" then
          return
        end
        M.pick()
      end,
    },
  }
end

return M
