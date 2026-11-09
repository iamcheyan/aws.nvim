--- Upload the AWS resource that backs the current buffer.
--- Resolution order: .aws-resource.json (walking up), legacy .aws-meta.json,
--- directory layout (lambda/, stepfunctions/, glue/), AWS Explorer selection.
local M = {}

--- Files and directories that never belong in a deployment archive.
local EXCLUDES = {
  ".git",
  ".git/*",
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
}

--- Directory names that identify a resource type.
local LAYOUT = {
  lambda = "lambda",
  stepfunctions = "stepfunctions",
  glue = "glue",
}

M.last_result = nil

local function notify(message, level)
  vim.notify("aws.nvim: " .. message, level or vim.log.levels.INFO)
end

local function valid_name(name)
  return type(name) == "string" and name:match("^[%w_.-]+$") ~= nil
end

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then
    return nil
  end
  return data
end

local function join(dir, name)
  if dir:sub(-1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

--- Pick the directory that holds the resource sources.
local function resolve_dir(root, kind, name)
  if name then
    local nested = join(join(root, kind), name)
    if exists(nested) then
      return nested
    end
    local flat = join(root, name)
    if exists(flat) then
      return flat
    end
  end
  return root
end

--- Infer a resource from the AWS Explorer buffer under the cursor.
local function discover_from_explorer()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "aws-lambda" then
    return nil
  end
  local line = vim.api.nvim_get_current_line() or ""
  local name = line:match("^([%w_.-]+)%s")
  if not name then
    return nil
  end
  local region = vim.api.nvim_buf_get_name(buf):match("^aws://lambda/functions/(.+)$")
  local cwd = vim.fn.getcwd()
  local dir = join(join(cwd, "lambda"), name)
  return {
    type = "lambda",
    name = name,
    region = region,
    dir = exists(dir) and dir or cwd,
    source = "explorer",
  }
end

--- Detect the resource that owns the given path (defaults to the current buffer).
---@param path string|nil
---@return table|nil resource, string|nil error
function M.discover(path)
  local start = path
  if not start or start == "" then
    start = vim.api.nvim_buf_get_name(0)
  end
  local dir = start ~= "" and vim.fs.dirname(start) or vim.fn.getcwd()
  if dir == "" then
    dir = "/"
  end
  if vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end

  local child = dir
  local cur = dir
  while cur and cur ~= "" do
    local resource_path = join(cur, ".aws-resource.json")
    local data = read_json(resource_path)
    if data then
      local kind = type(data.type) == "string" and data.type:lower() or nil
      if not kind or not LAYOUT[kind] then
        return nil, "unsupported .aws-resource.json type: " .. tostring(data.type)
      end
      local name = data.function_name or data.name or data.job_name or data.state_machine_name
      return {
        type = kind,
        name = name,
        region = data.region,
        profile = data.profile,
        dir = resolve_dir(cur, LAYOUT[kind], name),
        metadata = resource_path,
        source = "resource",
      }
    end

    local legacy = read_json(join(cur, ".aws-meta.json"))
    if legacy and type(legacy.function_name) == "string" then
      return {
        type = "lambda",
        name = legacy.function_name,
        region = legacy.region,
        dir = cur,
        metadata = join(cur, ".aws-meta.json"),
        source = "meta",
      }
    end

    local base = vim.fs.basename(cur)
    if LAYOUT[base] then
      local name = vim.fs.basename(child)
      return {
        type = base,
        name = name ~= "" and name ~= base and name or nil,
        dir = child,
        source = "layout",
      }
    end

    local parent = vim.fs.dirname(cur)
    if parent == cur then
      break
    end
    child = cur
    cur = parent
  end

  local explorer = discover_from_explorer()
  if explorer then
    return explorer
  end
  return nil, "no .aws-resource.json, .aws-meta.json or recognised resource directory found"
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
    "Uploading Lambda:",
    "  " .. tostring(resource.name),
    "Profile:",
    "  " .. tostring(resource.profile or "(default)"),
    "Region:",
    "  " .. tostring(resource.region or "(default)"),
    "Archive:",
    "  function.zip",
  }
  local width = 48
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
    "Uploading %s:\n  %s\nProfile:\n  %s\nRegion:\n  %s",
    resource.type == "lambda" and "Lambda" or resource.type,
    tostring(resource.name),
    tostring(resource.profile or "(default)"),
    tostring(resource.region or "(default)")
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
        title = "Lambda Upload Success",
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
