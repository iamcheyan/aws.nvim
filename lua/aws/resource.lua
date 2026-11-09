--- aws.nvim – unified AWS resource actions.
--- Discovers the resource behind the current buffer from `.aws-resource.json`
--- and exposes download / upload / invoke / logs / refresh / metadata actions.
local M = {}

local METADATA = ".aws-resource.json"
local LEGACY_METADATA = ".aws-meta.json"

--- Directory names that identify a resource type.
local LAYOUT = {
  lambda = "lambda",
  stepfunctions = "stepfunctions",
  glue = "glue",
}

M.METADATA = METADATA
M.last_result = nil

local function notify(message, level)
  vim.notify("aws.nvim: " .. message, level or vim.log.levels.INFO)
end

local function notify_resource_error(message)
  vim.notify("❌ " .. message, vim.log.levels.ERROR)
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
  local filetype = vim.bo[buf].filetype
  local line = vim.api.nvim_get_current_line() or ""
  local name = line:match("^([%w_.-]+)%s")
  if not name then
    return nil
  end

  if filetype == "aws-lambda" then
    local region = vim.api.nvim_buf_get_name(buf):match("^aws://lambda/functions/(.+)$")
    local cwd = vim.fn.getcwd()
    local dir = join(join(cwd, "lambda"), name)
    return {
      type = "lambda",
      name = name,
      region = region,
      dir = exists(dir) and dir or cwd,
      source = "explorer",
      data = { type = "lambda", function_name = name, region = region },
    }
  end
  return nil
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
    local metadata_path = join(cur, METADATA)
    local data = read_json(metadata_path)
    if data then
      local kind = type(data.type) == "string" and data.type:lower() or nil
      if not kind or not LAYOUT[kind] then
        return nil, "unsupported .aws-resource.json type: " .. tostring(data.type)
      end
      local name = data.function_name or data.name or data.job_name or data.state_machine_name
      return {
        type = kind,
        name = name,
        account = data.account,
        region = data.region,
        profile = data.profile,
        log_group = data.log_group,
        dir = resolve_dir(cur, LAYOUT[kind], name),
        metadata = metadata_path,
        source = "resource",
        data = data,
      }
    end

    local legacy = read_json(join(cur, LEGACY_METADATA))
    if legacy and type(legacy.function_name) == "string" then
      return {
        type = "lambda",
        name = legacy.function_name,
        account = legacy.account,
        region = legacy.region,
        dir = cur,
        metadata = join(cur, LEGACY_METADATA),
        source = "meta",
        data = legacy,
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
        data = { type = base, function_name = name },
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

--- Discover the resource or report the standard metadata error and stop.
---@return table|nil
function M.require_resource()
  local resource, err = M.discover()
  if not resource then
    notify_resource_error("AWS resource metadata not found")
    if err then
      notify(err, vim.log.levels.WARN)
    end
    return nil
  end
  return resource
end

--- Persist metadata for a resource directory.
---@param resource table
---@param updates  table|nil extra fields merged over the existing metadata
---@return string|nil path
function M.write_metadata(resource, updates)
  if not resource or not resource.dir or vim.fn.isdirectory(resource.dir) == 0 then
    return nil
  end
  local data = vim.deepcopy(resource.data or {})
  data.type = data.type or resource.type
  if resource.type == "lambda" then
    data.function_name = data.function_name or resource.name
  end
  data.account = data.account or resource.account
  data.region = data.region or resource.region
  data.profile = data.profile or resource.profile
  data.log_group = data.log_group or resource.log_group
  for key, value in pairs(updates or {}) do
    data[key] = value
  end
  for key, value in pairs(data) do
    if value == vim.NIL or value == nil then
      data[key] = nil
    end
  end
  local path = join(resource.dir, METADATA)
  local ok = pcall(vim.fn.writefile, { vim.json.encode(data) }, path)
  if not ok then
    notify("could not write " .. path, vim.log.levels.ERROR)
    return nil
  end
  resource.metadata = path
  resource.data = data
  return path
end

--- Save every modified normal buffer.
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

local function show_lines(title, lines)
  pcall(function()
    require("aws.lambda.workflow").show_text(title, lines, "aws://resource/result")
  end)
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

local function aws_args(args, resource, call_opts)
  local opts = vim.tbl_extend("force", {
    profile = resource and resource.profile or nil,
    region = resource and resource.region or nil,
  }, call_opts or {})
  local out = { "aws" }
  if opts.profile then
    vim.list_extend(out, { "--profile", opts.profile })
  end
  if opts.region then
    vim.list_extend(out, { "--region", opts.region })
  end
  vim.list_extend(out, args)
  return out
end

-------------------------------------------------------------------------------
-- Download
-------------------------------------------------------------------------------

--- Download the resource sources described by the metadata (Lambda today).
---@param call_opts table|nil
---@param callback fun(result: table)|nil
function M.download(call_opts, callback)
  local resource = M.require_resource()
  if not resource then
    if callback then
      callback({ ok = false, error = "AWS resource metadata not found" })
    end
    return
  end
  if resource.type ~= "lambda" then
    local result = { ok = false, error = resource.type .. " download is not implemented yet", callback = callback }
    M.last_result = result
    notify(result.error, vim.log.levels.WARN)
    if callback then
      callback(result)
    end
    return
  end
  if not valid_name(resource.name) then
    local result = { ok = false, error = "invalid Lambda function name in metadata", callback = callback }
    M.last_result = result
    notify_resource_error(result.error)
    if callback then
      callback(result)
    end
    return
  end
  require("aws.lambda.workflow").download_source(resource.name, call_opts, function(root, entry)
    local result = { ok = true, title = "Download Success", root = root, entry = entry, callback = callback }
    M.last_result = result
    if callback then
      callback(result)
    end
  end)
end

-------------------------------------------------------------------------------
-- Upload
-------------------------------------------------------------------------------

--- Upload the resource behind the current buffer.
---@param call_opts table|nil
---@param callback fun(result: table)|nil
function M.upload(call_opts, callback)
  require("aws.upload").upload(call_opts, callback)
end

-------------------------------------------------------------------------------
-- Invoke
-------------------------------------------------------------------------------

--- Invoke the Lambda described by the metadata with invoke.json.
---@param call_opts table|nil
---@param callback fun(result: table)|nil
function M.invoke(call_opts, callback)
  local res = M.require_resource()
  local function finish(result)
    M.last_result = result
    if callback then
      callback(result)
    end
  end
  if not res then
    finish({ ok = false, error = "AWS resource metadata not found" })
    return
  end
  if res.type ~= "lambda" then
    notify(res.type .. " invoke is not implemented yet", vim.log.levels.WARN)
    finish({ ok = false, error = res.type .. " invoke is not implemented yet" })
    return
  end

  local workflow = require("aws.lambda.workflow")
  local binding = { region = res.region, profile = res.profile }
  workflow.invoke_file(res.dir, res.name, call_opts, function(result)
    if not result.ok then
      if not result.created then
        vim.api.nvim_echo({ { "❌ Invoke Failed", "DiagnosticError" } }, true, {})
        show_lines("Invoke Failed", vim.split(tostring(result.error or "invoke failed"), "\n", { plain = true }))
      end
      finish(result)
      return
    end
    vim.api.nvim_echo({ { "✅ Invoke Success", "DiagnosticOk" } }, true, {})
    show_lines("Lambda Invoke", {
      "✅ Invoke Success",
      "",
      "Function:",
      "  " .. tostring(res.name),
      "StatusCode:",
      "  " .. tostring(result.status or "unknown"),
      "FunctionError:",
      "  " .. tostring(result.function_error or "none"),
      "ExecutedVersion:",
      "  " .. tostring(result.executed_version or "-"),
      "Payload:",
      "  " .. tostring(result.payload_path or "-"),
      "Response:",
      "  " .. tostring(result.response_path or "-"),
    })
    finish(result)
  end, binding)
end

-------------------------------------------------------------------------------
-- Logs
-------------------------------------------------------------------------------

--- Tail CloudWatch logs for the resource (log_group from metadata, else Lambda default).
---@param call_opts table|nil
function M.logs(call_opts)
  local resource = M.require_resource()
  if not resource then
    return
  end
  if resource.type ~= "lambda" then
    notify(resource.type .. " logs are not implemented yet", vim.log.levels.WARN)
    return
  end
  local log_group = resource.log_group
  if type(log_group) ~= "string" or log_group == "" then
    log_group = "/aws/lambda/" .. tostring(resource.name)
  end
  local opts = vim.tbl_extend("force", {
    profile = resource.profile,
    region = resource.region,
  }, call_opts or {})
  require("aws.lambda.workflow").tail_logs(opts, resource.name, log_group)
end

-------------------------------------------------------------------------------
-- Refresh
-------------------------------------------------------------------------------

--- Re-read the remote configuration and sync it back into .aws-resource.json.
---@param call_opts table|nil
---@param callback fun(result: table)|nil
function M.refresh(call_opts, callback)
  local resource = M.require_resource()
  local function finish(result)
    M.last_result = result
    if callback then
      callback(result)
    end
  end
  if not resource then
    finish({ ok = false, error = "AWS resource metadata not found" })
    return
  end
  if resource.type ~= "lambda" then
    notify(resource.type .. " refresh is not implemented yet", vim.log.levels.WARN)
    finish({ ok = false, error = resource.type .. " refresh is not implemented yet" })
    return
  end

  local args = aws_args({
    "lambda",
    "get-function-configuration",
    "--function-name",
    resource.name,
    "--output",
    "json",
  }, resource, call_opts)

  run(args, { text = true }, function(result)
    if result.code ~= 0 then
      vim.api.nvim_echo({ { "❌ Refresh Failed", "DiagnosticError" } }, true, {})
      show_lines("Refresh Failed", vim.split(vim.trim(result.stderr or "AWS CLI failed"), "\n", { plain = true }))
      finish({ ok = false, error = vim.trim(result.stderr or "AWS CLI failed") })
      return
    end
    local ok, data = pcall(vim.json.decode, result.stdout or "{}")
    if not ok or type(data) ~= "table" then
      notify("could not parse get-function-configuration output", vim.log.levels.ERROR)
      finish({ ok = false, error = "could not parse get-function-configuration output" })
      return
    end

    local env_keys = {}
    if type(data.Environment) == "table" and type(data.Environment.Variables) == "table" then
      for key in pairs(data.Environment.Variables) do
        table.insert(env_keys, key)
      end
      table.sort(env_keys)
    end
    local architectures = type(data.Architectures) == "table" and table.concat(data.Architectures, ",") or "-"

    local updates = {
      runtime = data.Runtime,
      architecture = architectures,
      memory_mb = data.MemorySize,
      timeout_s = data.Timeout,
      handler = data.Handler,
      code_sha256 = data.CodeSha256,
      code_size = data.CodeSize,
      last_modified = data.LastModified,
      function_arn = data.FunctionArn,
      environment_keys = #env_keys > 0 and env_keys or nil,
      refreshed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    M.write_metadata(resource, updates)

    local lines = {
      "✅ Resource Refreshed",
      "",
      "Function:",
      "  " .. tostring(resource.name),
      "Runtime:",
      "  " .. tostring(data.Runtime or "-"),
      "Architecture:",
      "  " .. architectures,
      "Memory:",
      "  " .. tostring(data.MemorySize or "-") .. " MB",
      "Timeout:",
      "  " .. tostring(data.Timeout or "-") .. " s",
      "Handler:",
      "  " .. tostring(data.Handler or "-"),
      "CodeSha256:",
      "  " .. tostring(data.CodeSha256 or "-"),
      "CodeSize:",
      "  " .. tostring(data.CodeSize or "-") .. " bytes",
      "LastModified:",
      "  " .. tostring(data.LastModified or "-"),
      "Environment:",
      "  " .. (#env_keys > 0 and table.concat(env_keys, ", ") or "(none)"),
      "Metadata:",
      "  " .. tostring(resource.metadata or METADATA),
    }
    vim.api.nvim_echo({ { "✅ Resource Refreshed", "DiagnosticOk" } }, true, {})
    show_lines("AWS Resource Refresh", lines)
    finish({ ok = true, configuration = data, updates = updates })
  end)
end

-------------------------------------------------------------------------------
-- Metadata
-------------------------------------------------------------------------------

--- Show the metadata file that the current buffer belongs to.
function M.show_metadata()
  local resource = M.require_resource()
  if not resource then
    return
  end
  local data = read_json(resource.metadata) or resource.data or {}
  local lines = { "✅ AWS resource metadata", "", tostring(resource.metadata), "" }
  local encoded = vim.split(vim.json.encode(data), "\n", { plain = true })
  for _, line in ipairs(encoded) do
    table.insert(lines, line)
  end
  show_lines("AWS Resource Metadata", lines)
  M.last_result = { ok = true, metadata = resource.metadata, data = data }
end

return M
