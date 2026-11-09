--- Upload the AWS resource that backs the current buffer.
--- Resolution order: .aws-resource.json (walking up), legacy .aws-meta.json,
--- directory layout (lambda/, stepfunctions/, glue/), AWS Explorer selection.
local M = {}

--- Files and directories that never belong in a deployment archive.
local EXCLUDES = {
  ".git",
  ".git/*",
  ".github",
  ".github/*",
  "__pycache__",
  "__pycache__/*",
  ".pytest_cache",
  ".pytest_cache/*",
  ".venv",
  ".venv/*",
  "node_modules",
  "node_modules/*",
  "*.pyc",
  "function.zip",
  ".aws-resource.json",
}

M.last_result = nil

local function notify(message, level)
  vim.notify("aws.nvim: " .. message, level or vim.log.levels.INFO)
end

local function valid_name(name)
  return type(name) == "string" and name:match("^[%w_.-]+$") ~= nil
end

local function join(dir, name)
  if dir:sub(-1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

--- Discover the resource behind the current buffer (see aws.resource).
function M.discover(path)
  return require("aws.resource").discover(path)
end

--- Save every modified normal buffer so the archive contains what is on screen.
---@return boolean saved
function M.save_all()
  local modified = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.bo[buf].buftype == "" then
      modified = true
      break
    end
  end
  if modified then
    vim.cmd("silent! wall")
  end
  return modified
end

local function show_result(title, lines)
  pcall(function()
    require("aws.lambda.workflow").show_text(title, lines, "aws://upload/result")
  end)
end

local banner = { win = nil, buf = nil }

local function close_banner()
  if banner.win and vim.api.nvim_win_is_valid(banner.win) then
    pcall(vim.api.nvim_win_close, banner.win, true)
  end
  banner.win, banner.buf = nil, nil
end

--- Show the pre-upload safety banner until the upload finishes.
local function open_banner(resource)
  close_banner()
  local lines = {
    "Uploading Lambda…",
    "",
    "Function:",
    "  " .. tostring(resource.name),
    "Profile:",
    "  " .. tostring(resource.profile or "(default)"),
    "Region:",
    "  " .. tostring(resource.region or "(default)"),
    "Account:",
    "  " .. tostring(resource.account or "(unknown)"),
  }
  local width = 52
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = #lines,
    row = 1,
    col = math.max(0, vim.o.columns - width - 4),
    title = " AWS Upload ",
    title_pos = "center",
  })
  if ok then
    banner.win, banner.buf = win, buf
  end
end

--- Whether the safety banner is currently visible (used by tests).
function M.banner_open()
  return banner.win ~= nil and vim.api.nvim_win_is_valid(banner.win)
end

local function describe(resource)
  return string.format(
    "Uploading %s:\n  %s\nProfile:\n  %s\nRegion:\n  %s\nAccount:\n  %s",
    resource.type == "lambda" and "Lambda" or resource.type,
    tostring(resource.name),
    tostring(resource.profile or "(default)"),
    tostring(resource.region or "(default)"),
    tostring(resource.account or "(unknown)")
  )
end

local function finish(result, resource)
  close_banner()
  M.last_result = result
  if result.ok then
    vim.api.nvim_echo({ { "✅ " .. result.title, "DiagnosticOk" } }, true, {})
    show_result(result.title, {
      "✅ " .. result.title,
      "",
      "Function:",
      "  " .. tostring(resource.name),
      "Region:",
      "  " .. tostring(resource.region or "(default)"),
      "Account:",
      "  " .. tostring(resource.account or "(unknown)"),
      "Profile:",
      "  " .. tostring(resource.profile or "(default)"),
      "Archive:",
      "  " .. tostring(result.archive or "-"),
    })
  else
    vim.api.nvim_echo({ { "❌ Upload Failed", "DiagnosticError" } }, true, {})
    show_result("Upload Failed", vim.split(result.error or "unknown error", "\n", { plain = true }))
  end
  if result.callback then
    result.callback(result)
  end
end

local function run(cmd, opts, callback)
  local ok, proc = pcall(vim.system, cmd, opts or {}, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
  if not ok then
    callback({ code = 1, stderr = tostring(proc), stdout = "" })
    return
  end
  return proc
end

local function aws_args(args, resource)
  local out = { "aws" }
  if resource.profile then
    vim.list_extend(out, { "--profile", resource.profile })
  end
  if resource.region then
    vim.list_extend(out, { "--region", resource.region })
  end
  vim.list_extend(out, args)
  return out
end

--- Package and upload a Lambda function.
---@param resource table
---@param callback fun(result: table)|nil
function M.upload_lambda(resource, callback)
  if not valid_name(resource.name) then
    local result = { ok = false, error = "invalid Lambda function name in metadata", callback = callback }
    finish(result, resource)
    return
  end

  M.save_all()
  local archive = join(resource.dir, "function.zip")
  vim.fn.delete(archive)

  local zip_args = { "zip", "-r", "function.zip", ".", "-x" }
  vim.list_extend(zip_args, EXCLUDES)
  open_banner(resource)
  notify(describe(resource))

  run(zip_args, { cwd = resource.dir, text = true }, function(zipped)
    if zipped.code ~= 0 then
      finish({
        ok = false,
        error = "zip failed:\n" .. vim.trim(zipped.stderr or "") .. "\n" .. vim.trim(zipped.stdout or ""),
        callback = callback,
        archive = archive,
      }, resource)
      return
    end
    local args = aws_args({
      "lambda",
      "update-function-code",
      "--function-name",
      resource.name,
      "--zip-file",
      "fileb://" .. archive,
    }, resource)
    run(args, { text = true }, function(uploaded)
      if uploaded.code ~= 0 then
        finish({
          ok = false,
          error = vim.trim(uploaded.stderr or "AWS CLI upload failed"),
          callback = callback,
          archive = archive,
        }, resource)
        return
      end
      finish({
        ok = true,
        title = "Upload Success",
        archive = archive,
        output = vim.trim(uploaded.stdout or ""),
        callback = callback,
      }, resource)
    end)
  end)
end

--- Upload the resource that owns the current buffer.
---@param call_opts table|nil { profile = string, region = string }
---@param callback fun(result: table)|nil
function M.upload(call_opts, callback)
  local resource, err = M.discover()
  if not resource then
    local result = { ok = false, error = err or "no AWS resource detected", callback = callback }
    M.last_result = result
    notify(result.error, vim.log.levels.ERROR)
    if callback then
      callback(result)
    end
    return
  end

  resource.profile = (call_opts and call_opts.profile) or resource.profile
  resource.region = (call_opts and call_opts.region) or resource.region

  if resource.type == "lambda" then
    M.upload_lambda(resource, callback)
    return
  end

  local result = {
    ok = false,
    error = string.format(
      "%s resources are recognised but uploading them is not implemented yet",
      resource.type == "stepfunctions" and "Step Functions" or "Glue"
    ),
    callback = callback,
    resource = resource,
  }
  M.last_result = result
  notify(result.error, vim.log.levels.WARN)
  if callback then
    callback(result)
  end
end

return M
