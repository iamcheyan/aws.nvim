--- Lambda source download, deployment, invocation, and live logs.
local M = {}

local active_tails = {}
local auto_deploy_busy = {}

local function notify(message, level)
  vim.schedule(function()
    vim.notify("aws.nvim: " .. message, level or vim.log.levels.INFO)
  end)
end

local function aws_args(args, call_opts)
  local out = { "aws" }
  if call_opts and call_opts.profile then
    vim.list_extend(out, { "--profile", call_opts.profile })
  end
  if call_opts and call_opts.region then
    vim.list_extend(out, { "--region", call_opts.region })
  end
  vim.list_extend(out, args)
  return out
end

local function run(cmd, opts, callback)
  local ok, proc = pcall(vim.system, cmd, opts or {}, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
  if not ok then
    callback({ code = 1, stderr = tostring(proc), stdout = "" })
    return nil
  end
  return proc
end

local function display_buffer(title, lines, buffer_name)
  local buf = vim.api.nvim_create_buf(false, true)
  if buffer_name then
    vim.api.nvim_buf_set_name(buf, buffer_name)
  end
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "json"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local width = math.max(40, math.min(vim.o.columns - 4, 100))
  local height = math.max(5, math.min(vim.o.lines - 6, #lines + 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2 - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = buf, silent = true, desc = "Close Lambda result" })
  return buf, win
end

local function valid_function_name(name)
  return type(name) == "string" and name:match("^[%w_-]+$") ~= nil and name ~= "." and name ~= ".."
end

local function metadata_path(function_dir)
  return function_dir .. "/.aws-meta.json"
end

local function safe_archive_listing(output)
  for _, entry in ipairs(vim.split(output or "", "\n", { plain = true, trimempty = true })) do
    if entry:match("^/") or entry:match("^[%a]:") or entry:find("\\\\", 1, true) then
      return false
    end
    for part in entry:gmatch("[^/]+") do
      if part == ".." then
        return false
      end
    end
  end
  return true
end

local function resolve_region_async(call_opts, callback)
  local config = require("aws.config")
  local region = (call_opts and call_opts.region)
    or config.values.default_aws_region
    or vim.env.AWS_DEFAULT_REGION
    or vim.env.AWS_REGION
  if region then
    callback(region)
    return
  end
  local args = { "aws" }
  if call_opts and call_opts.profile then
    vim.list_extend(args, { "--profile", call_opts.profile })
  end
  vim.list_extend(args, { "configure", "get", "region" })
  run(args, { text = true }, function(result)
    callback(result.code == 0 and vim.trim(result.stdout or "") or "unknown")
  end)
end

local function read_binding(path)
  local dir = vim.fs.dirname(path)
  while dir and dir ~= "/" do
    local meta = metadata_path(dir)
    if vim.fn.filereadable(meta) == 1 then
      local raw = table.concat(vim.fn.readfile(meta), "\n")
      local ok, data = pcall(vim.json.decode, raw)
      if ok and type(data) == "table" and valid_function_name(data.function_name) then
        local lambda_dir = vim.fs.dirname(dir)
        local aws_dir = vim.fs.dirname(lambda_dir)
        if vim.fs.basename(lambda_dir) == "lambda" and vim.fs.basename(aws_dir) == ".aws" then
          return data, dir
        end
      end
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
end

local function current_binding()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    notify("save the current file before using this Lambda action", vim.log.levels.WARN)
    return
  end
  local binding, dir = read_binding(path)
  if not binding then
    notify("current file is not inside a bound .aws/lambda/<function> directory", vim.log.levels.WARN)
    return
  end
  return binding, dir
end

local function get_call_opts(meta, call_opts)
  local opts = vim.tbl_extend("force", {}, call_opts or {})
  opts.region = opts.region or meta.region
  return opts
end

local function archive_and_upload(meta, dir, call_opts, done)
  local name = meta.function_name
  if not valid_function_name(name) then
    notify("invalid function name in .aws-meta.json", vim.log.levels.ERROR)
    if done then
      done(false)
    end
    return
  end
  local archive = vim.fn.tempname() .. ".zip"
  run({ "zip", "-qr", archive, ".", "-x", ".aws-meta.json" }, { cwd = dir, text = true }, function(zip_result)
    if zip_result.code ~= 0 then
      vim.fn.delete(archive)
      notify("failed to create deployment archive: " .. (zip_result.stderr or "zip failed"), vim.log.levels.ERROR)
      if done then
        done(false)
      end
      return
    end
    local args = aws_args(
      { "lambda", "update-function-code", "--function-name", name, "--zip-file", "fileb://" .. archive },
      call_opts
    )
    run(args, { text = true }, function(result)
      vim.fn.delete(archive)
      if result.code == 0 then
        notify("Lambda deployed successfully")
      else
        notify(vim.trim(result.stderr or "AWS CLI upload failed"), vim.log.levels.ERROR)
      end
      if done then
        done(result.code == 0)
      end
    end)
  end)
end

function M.download_source(function_name, call_opts)
  if not valid_function_name(function_name) then
    notify("invalid Lambda function name", vim.log.levels.ERROR)
    return
  end
  local opts = call_opts or {}
  local get_args = aws_args({ "lambda", "get-function", "--function-name", function_name, "--output", "json" }, opts)
  notify("fetching source for " .. function_name .. "…")
  run(get_args, { text = true }, function(result)
    if result.code ~= 0 then
      notify(vim.trim(result.stderr or "AWS CLI get-function failed"), vim.log.levels.ERROR)
      return
    end
    local ok, data = pcall(vim.json.decode, result.stdout or "")
    local location = ok and data and data.Code and data.Code.Location
    if type(location) ~= "string" or location == "" then
      notify("AWS get-function response did not include Code.Location", vim.log.levels.ERROR)
      return
    end
    local cwd = vim.fn.getcwd()
    local lambda_root = cwd .. "/.aws/lambda"
    local root = lambda_root .. "/" .. function_name
    local stage = lambda_root .. "/." .. function_name .. ".download-" .. vim.fn.getpid() .. "-" .. vim.uv.hrtime()
    local backup = lambda_root .. "/." .. function_name .. ".backup-" .. vim.fn.getpid() .. "-" .. vim.uv.hrtime()
    local zipfile = vim.fn.tempname() .. ".zip"
    vim.fn.mkdir(lambda_root, "p")
    local last_percent, last_update = nil, 0
    local progress_id = vim.notify("aws.nvim: downloading " .. function_name .. " (0%)…", vim.log.levels.INFO)
    run({ "curl", "-L", "--fail", "--silent", "--show-error", "--progress-bar", "--output", zipfile, location }, {
      text = true,
      stderr = function(_, chunk)
        if not chunk then
          return
        end
        local percent
        for value in chunk:gmatch("(%d?%d?%d)%%") do
          percent = tonumber(value)
        end
        if percent and percent ~= last_percent and vim.uv.now() - last_update > 250 then
          last_percent, last_update = percent, vim.uv.now()
          vim.schedule(function()
            vim.notify(
              "aws.nvim: downloading " .. function_name .. " (" .. percent .. "%)…",
              vim.log.levels.INFO,
              { replace = progress_id }
            )
          end)
        end
      end,
    }, function(download)
      if download.code ~= 0 then
        vim.fn.delete(zipfile)
        notify(vim.trim(download.stderr or "curl download failed"), vim.log.levels.ERROR)
        return
      end
      run({ "unzip", "-Z1", zipfile }, { text = true }, function(listing)
        if listing.code ~= 0 or not safe_archive_listing(listing.stdout) then
          vim.fn.delete(zipfile)
          notify("downloaded archive contains invalid paths", vim.log.levels.ERROR)
          return
        end
        run({ "zipinfo", "-l", zipfile }, { text = true }, function(details)
          local has_symlink = false
          for _, line in ipairs(vim.split(details.stdout or "", "\n", { plain = true })) do
            if line:match("^l[rwx-]+%s") then
              has_symlink = true
            end
          end
          if details.code ~= 0 or has_symlink then
            vim.fn.delete(zipfile)
            notify(
              has_symlink and "downloaded archive contains a symbolic link" or "could not inspect downloaded archive",
              vim.log.levels.ERROR
            )
            return
          end
          notify("extracting " .. function_name .. "…")
          vim.fn.mkdir(stage, "p")
          run({ "unzip", "-q", zipfile, "-d", stage }, { text = true }, function(unpacked)
            vim.fn.delete(zipfile)
            if unpacked.code ~= 0 then
              vim.fn.delete(stage, "rf")
              notify(vim.trim(unpacked.stderr or "unzip failed"), vim.log.levels.ERROR)
              return
            end
            local effective = get_call_opts({}, opts)
            local identity_args =
              aws_args({ "sts", "get-caller-identity", "--query", "Account", "--output", "text" }, effective)
            run(identity_args, { text = true }, function(identity)
              resolve_region_async(effective, function(region)
                local account = identity.code == 0 and vim.trim(identity.stdout or "") or "unknown"
                local meta = { function_name = function_name, region = region, account = account }
                if vim.fn.writefile({ vim.json.encode(meta) }, metadata_path(stage)) ~= 0 then
                  vim.fn.delete(stage, "rf")
                  notify("could not write Lambda binding metadata", vim.log.levels.ERROR)
                  return
                end

                local had_root = vim.uv.fs_stat(root) ~= nil
                if had_root and vim.fn.rename(root, backup) ~= 0 then
                  vim.fn.delete(stage, "rf")
                  notify("could not preserve existing Lambda cache", vim.log.levels.ERROR)
                  return
                end
                if vim.fn.rename(stage, root) ~= 0 then
                  if had_root then
                    vim.fn.rename(backup, root)
                  end
                  vim.fn.delete(stage, "rf")
                  notify("could not publish downloaded Lambda source", vim.log.levels.ERROR)
                  return
                end
                if had_root then
                  vim.fn.delete(backup, "rf")
                end

                local candidates = { "app.py", "index.js", "handler.py", "main.py" }
                for _, candidate in ipairs(candidates) do
                  local entry = root .. "/" .. candidate
                  if vim.fn.filereadable(entry) == 1 then
                    vim.cmd.edit(vim.fn.fnameescape(entry))
                    notify("source downloaded to " .. vim.fn.fnamemodify(root, ":~"))
                    if identity.code ~= 0 then
                      notify("could not read AWS account; binding saved as unknown", vim.log.levels.WARN)
                    end
                    return
                  end
                end
                vim.cmd.edit(vim.fn.fnameescape(root))
                notify("source downloaded to " .. vim.fn.fnamemodify(root, ":~"))
                if identity.code ~= 0 then
                  notify("could not read AWS account; binding saved as unknown", vim.log.levels.WARN)
                end
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

local function binding_for_function(function_name)
  if not valid_function_name(function_name) then
    notify("invalid Lambda function name", vim.log.levels.ERROR)
    return
  end
  local root = vim.fn.getcwd() .. "/.aws/lambda/" .. function_name
  local meta, dir = read_binding(metadata_path(root))
  if not meta or dir ~= root or meta.function_name ~= function_name then
    notify("no local source binding for Lambda " .. function_name, vim.log.levels.WARN)
    return
  end
  return meta, dir
end

function M.upload_current(call_opts, done)
  local meta, dir = current_binding()
  if meta then
    archive_and_upload(meta, dir, get_call_opts(meta, call_opts), done)
  end
end

function M.upload_function(function_name, call_opts, done)
  local meta, dir = binding_for_function(function_name)
  if meta then
    archive_and_upload(meta, dir, get_call_opts(meta, call_opts), done)
  end
end

local function invoke(meta, call_opts)
  local opts = get_call_opts(meta, call_opts)
  vim.ui.input({ prompt = "Lambda event JSON: ", default = "{}" }, function(event)
    if event == nil then
      return
    end
    local decoded, payload = pcall(vim.json.decode, event)
    if not decoded then
      notify("invalid JSON event: " .. tostring(payload), vim.log.levels.ERROR)
      return
    end
    local input = vim.fn.tempname() .. ".json"
    local output = vim.fn.tempname() .. ".json"
    if vim.fn.writefile({ event }, input) ~= 0 then
      notify("could not write Lambda event input", vim.log.levels.ERROR)
      return
    end
    local args = aws_args({
      "lambda",
      "invoke",
      "--function-name",
      meta.function_name,
      "--payload",
      "fileb://" .. input,
      "--cli-binary-format",
      "raw-in-base64-out",
      "--log-type",
      "Tail",
      output,
    }, opts)
    run(args, { text = true }, function(result)
      vim.fn.delete(input)
      if result.code ~= 0 then
        vim.fn.delete(output)
        notify(vim.trim(result.stderr or "AWS CLI invoke failed"), vim.log.levels.ERROR)
        return
      end
      local response = vim.fn.filereadable(output) == 1 and table.concat(vim.fn.readfile(output), "\n")
        or "(empty response)"
      vim.fn.delete(output)
      local lines = { "Lambda response:", "" }
      vim.list_extend(lines, vim.split(response, "\n", { plain = true }))
      local meta_ok, invoke_meta = pcall(vim.json.decode, result.stdout or "{}")
      if meta_ok and type(invoke_meta) == "table" and invoke_meta.LogResult and vim.base64 then
        local log_ok, logs = pcall(vim.base64.decode, invoke_meta.LogResult)
        table.insert(lines, "")
        table.insert(lines, "Lambda logs:")
        if log_ok then
          vim.list_extend(lines, vim.split(logs, "\n", { plain = true }))
        else
          table.insert(lines, "(could not decode AWS log output)")
        end
      elseif not meta_ok then
        table.insert(lines, "")
        table.insert(lines, "AWS invoke metadata was not valid JSON:")
        vim.list_extend(lines, vim.split(result.stdout or "", "\n", { plain = true }))
      end
      display_buffer("Lambda Invoke: " .. meta.function_name, lines, "aws://lambda/invoke/" .. meta.function_name)
    end)
  end)
end

function M.invoke_current(call_opts)
  local meta = current_binding()
  if meta then
    invoke(meta, get_call_opts(meta, call_opts))
  end
end

function M.invoke_function(function_name, call_opts)
  local meta = binding_for_function(function_name)
  if meta then
    invoke(meta, get_call_opts(meta, call_opts))
  end
end

function M.upload_and_invoke(call_opts)
  local meta, dir = current_binding()
  if not meta then
    return
  end
  local opts = get_call_opts(meta, call_opts)
  archive_and_upload(meta, dir, opts, function(ok)
    if ok then
      invoke(meta, opts)
    end
  end)
end

function M.upload_and_invoke_function(function_name, call_opts)
  local meta, dir = binding_for_function(function_name)
  if not meta then
    return
  end
  local opts = get_call_opts(meta, call_opts)
  archive_and_upload(meta, dir, opts, function(ok)
    if ok then
      invoke(meta, opts)
    end
  end)
end

function M.tail_logs(call_opts, function_name)
  local name = function_name or vim.b.aws_lambda_function
  if name and not valid_function_name(name) then
    notify("invalid Lambda function name", vim.log.levels.ERROR)
    return
  end
  local meta
  if name then
    local root = vim.fn.getcwd() .. "/.aws/lambda/" .. name
    meta = read_binding(metadata_path(root)) or { function_name = name }
  else
    meta = current_binding()
    if not meta then
      return
    end
    name = meta.function_name
  end
  local opts = get_call_opts(meta, call_opts)
  local config = require("aws.config")
  local profile = opts.profile or config.resolve_profile(opts) or "<default>"
  local region = opts.region
    or config.values.default_aws_region
    or vim.env.AWS_DEFAULT_REGION
    or vim.env.AWS_REGION
    or "<configured>"
  local key = table.concat({ profile, region, name }, "|")
  if active_tails[key] then
    active_tails[key]:kill(15)
    active_tails[key] = nil
    notify("stopped live logs for " .. name)
    return
  end
  local bufname = "aws://lambda/logs/" .. key
  local existing = vim.fn.bufnr(bufname)
  local buf = existing >= 0 and vim.api.nvim_buf_is_valid(existing) and existing or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  if existing < 0 or not vim.api.nvim_buf_is_valid(existing) then
    vim.api.nvim_buf_set_name(buf, bufname)
  end
  vim.b[buf].aws_lambda_function = name
  vim.b[buf].aws_lambda_tail_key = key
  local win
  for _, candidate in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(candidate) and vim.api.nvim_win_get_buf(candidate) == buf then
      win = candidate
      break
    end
  end
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("botright 12split")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    { "Live Lambda logs: " .. name, "Press <S-L> or :AwsLambdaLogsStop to stop", "" }
  )
  vim.keymap.set("n", "<S-L>", function()
    M.tail_logs(call_opts, name)
  end, { buffer = buf, silent = true, desc = "Reconnect or stop Lambda logs" })
  local args = aws_args({ "logs", "tail", "/aws/lambda/" .. name, "--follow" }, opts)
  local proc = vim.system(args, {
    text = true,
    stdout = function(_, chunk)
      if not chunk or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          local new = vim.split(chunk, "\n", { plain = true, trimempty = true })
          vim.list_extend(lines, new)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
            vim.api.nvim_win_set_cursor(win, { #lines, 0 })
          end
        end
      end)
    end,
    stderr = function(_, chunk)
      if chunk then
        notify(vim.trim(chunk), vim.log.levels.ERROR)
      end
    end,
  }, function()
    active_tails[key] = nil
  end)
  active_tails[key] = proc
end

function M.stop_logs()
  local key = vim.b.aws_lambda_tail_key
  if key and active_tails[key] then
    active_tails[key]:kill(15)
    active_tails[key] = nil
    notify("stopped live logs for " .. (vim.b.aws_lambda_function or "Lambda"))
    return
  end
  for identity, proc in pairs(active_tails) do
    proc:kill(15)
    active_tails[identity] = nil
  end
end

function M.setup_auto_deploy(enabled)
  local group = vim.api.nvim_create_augroup("AwsLambdaAutoDeploy", { clear = true })
  if not enabled then
    return
  end
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      local path = vim.api.nvim_buf_get_name(event.buf)
      local meta, dir = read_binding(path)
      if not meta or path == metadata_path(dir) then
        return
      end
      local state = auto_deploy_busy[dir]
      if state then
        state.pending = true
        return
      end
      state = { pending = false }
      auto_deploy_busy[dir] = state
      local function deploy_latest()
        archive_and_upload(meta, dir, get_call_opts(meta), function()
          if state.pending then
            state.pending = false
            deploy_latest()
          else
            auto_deploy_busy[dir] = nil
          end
        end)
      end
      deploy_latest()
    end,
  })
end

return M
