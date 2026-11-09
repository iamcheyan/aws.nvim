--- Interactive Lambda invoke panel.
--- Opens a horizontal split with an editable JSON payload box and a row of
--- clickable buttons, in the spirit of an fzf/ripgrep interactive UI.
local M = {}

local DEFAULT_PAYLOAD = '{\n  "message": "hello from aws.nvim"\n}'

local BUTTONS = {
  { id = "invoke", label = "[ Invoke <C-s> ]" },
  { id = "upload_invoke", label = "[ Upload + Invoke ]" },
  { id = "copy", label = "[ Copy response ]" },
  { id = "close", label = "[ Close q ]" },
}

local state = {
  json_win = nil,
  json_buf = nil,
  bar_win = nil,
  bar_buf = nil,
  function_name = nil,
  call_opts = nil,
  buttons = {},
  status = "ready",
  busy = false,
  last_result = nil,
}

--- Payloads remembered per function so reopening the panel keeps the event.
local payloads = {}

local function valid_function_name(name)
  return type(name) == "string" and name:match("^[%w_-]+$") ~= nil and name ~= "." and name ~= ".."
end

local function notify(message, level)
  vim.schedule(function()
    vim.notify("aws.nvim: " .. message, level or vim.log.levels.INFO)
  end)
end

local function win_valid(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function define_highlights()
  vim.api.nvim_set_hl(0, "AwsInvokeBar", { link = "StatusLine", default = true })
  vim.api.nvim_set_hl(0, "AwsInvokeButton", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "AwsInvokeStatus", { link = "Comment", default = true })
end

local function bar_text()
  local parts, spans = {}, {}
  local col = 0
  for _, button in ipairs(BUTTONS) do
    table.insert(parts, button.label)
    table.insert(spans, { id = button.id, start = col, stop = col + #button.label - 1 })
    col = col + #button.label + 2
  end
  local status = "  │  " .. (state.function_name or "?") .. " · " .. state.status
  return table.concat(parts, "  ") .. status, spans
end

local function render_bar()
  if not (state.bar_buf and vim.api.nvim_buf_is_valid(state.bar_buf)) then
    return
  end
  local text, spans = bar_text()
  state.buttons = spans
  vim.bo[state.bar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.bar_buf, 0, -1, false, { "  " .. text })
  vim.bo[state.bar_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.bar_buf, -1, 0, -1)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_add_highlight(state.bar_buf, -1, "AwsInvokeButton", 0, span.start + 2, span.stop + 3)
  end
  local status_start = #text - #state.status
  vim.api.nvim_buf_add_highlight(state.bar_buf, -1, "AwsInvokeStatus", 0, status_start + 2, -1)
end

local function set_status(text)
  state.status = text
  render_bar()
end

local function close(opts)
  opts = opts or {}
  for _, win in ipairs({ state.bar_win, state.json_win }) do
    if win_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  if not opts.keep_payload and state.function_name then
    payloads[state.function_name] = nil
  end
  state.json_win, state.json_buf = nil, nil
  state.bar_win, state.bar_buf = nil, nil
  state.function_name, state.call_opts = nil, nil
  state.buttons, state.status, state.busy, state.last_result = {}, "ready", false, nil
end

local function current_payload()
  if not (state.json_buf and vim.api.nvim_buf_is_valid(state.json_buf)) then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(state.json_buf, 0, -1, false), "\n")
end

local function remember_payload()
  if state.function_name then
    local payload = current_payload()
    if payload then
      payloads[state.function_name] = payload
    end
  end
end

local function show_result(result)
  state.last_result = result
  local workflow = require("aws.lambda.workflow")
  workflow.show_text(
    "Lambda Invoke: " .. state.function_name,
    workflow.result_lines(result),
    "aws://lambda/invoke-result/" .. state.function_name
  )
end

local function do_invoke(upload_first)
  if state.busy then
    return
  end
  local payload = current_payload()
  if not payload then
    return
  end
  if not pcall(vim.json.decode, payload) then
    set_status("invalid JSON")
    notify("event payload is not valid JSON", vim.log.levels.ERROR)
    return
  end
  state.busy = true
  set_status(upload_first and "uploading…" or "invoking…")
  local workflow = require("aws.lambda.workflow")

  local function fire()
    workflow.invoke_payload(state.function_name, payload, state.call_opts, function(result)
      state.busy = false
      if not result.ok then
        set_status("failed")
        notify(result.error or "invoke failed", vim.log.levels.ERROR)
        return
      end
      set_status("ok · " .. tostring(result.status or "?"))
      show_result(result)
    end)
  end

  if not upload_first then
    fire()
    return
  end
  workflow.upload_function(state.function_name, state.call_opts, function(ok)
    if ok then
      set_status("invoking…")
      fire()
      return
    end
    state.busy = false
    set_status("upload failed")
  end)
end

local function copy_response()
  if not state.last_result or not state.last_result.response then
    set_status("nothing to copy")
    return
  end
  vim.fn.setreg('"', state.last_result.response)
  set_status("response copied")
end

--- Trigger a panel action by id: invoke | upload_invoke | copy | close.
---@param id string
function M.trigger(id)
  if id == "invoke" then
    do_invoke(false)
  elseif id == "upload_invoke" then
    do_invoke(true)
  elseif id == "copy" then
    copy_response()
  elseif id == "close" then
    remember_payload()
    close({ keep_payload = true })
  end
end

--- Button under a 1-based byte column in the button bar, if any.
---@param column integer
---@return string|nil
function M.button_at(column)
  for _, span in ipairs(state.buttons) do
    if column >= span.start + 3 and column <= span.stop + 3 then
      return span.id
    end
  end
end

--- Current panel state (used by tests and :checkhealth-style diagnostics).
function M.inspect()
  return {
    open = win_valid(state.json_win) and win_valid(state.bar_win),
    function_name = state.function_name,
    status = state.status,
    busy = state.busy,
    last_result = state.last_result,
    buttons = vim.deepcopy(state.buttons),
    json_win = state.json_win,
    bar_win = state.bar_win,
    json_buf = state.json_buf,
    bar_buf = state.bar_buf,
  }
end

function M.close()
  remember_payload()
  close({ keep_payload = true })
end

local function attach_json_keymaps(buf)
  local map = function(lhs, fn, desc)
    vim.keymap.set({ "n", "i" }, lhs, fn, { buffer = buf, silent = true, desc = "aws.nvim: " .. desc })
  end
  map("<C-s>", function()
    do_invoke(false)
  end, "invoke Lambda with the JSON payload")
  map("<C-CR>", function()
    do_invoke(false)
  end, "invoke Lambda with the JSON payload")
  vim.keymap.set("n", "<C-a>", function()
    do_invoke(true)
  end, { buffer = buf, silent = true, desc = "aws.nvim: upload then invoke Lambda" })
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buf, silent = true, desc = "aws.nvim: close invoke panel" })
  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, { buffer = buf, silent = true, desc = "aws.nvim: close invoke panel" })
end

local function attach_bar_keymaps(buf)
  local function click()
    local mouse = vim.fn.getmousepos()
    local id = M.button_at(mouse.column or 0)
    if id then
      M.trigger(id)
    end
  end
  vim.keymap.set({ "n", "i" }, "<LeftMouse>", click, { buffer = buf, silent = true, desc = "aws.nvim: invoke button" })
  vim.keymap.set("n", "<CR>", function()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local id = M.button_at(col + 1)
    if id then
      M.trigger(id)
    end
  end, { buffer = buf, silent = true, desc = "aws.nvim: invoke button" })
  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buf, silent = true, desc = "aws.nvim: close invoke panel" })
end

--- Open the interactive invoke panel for a Lambda function.
---@param function_name string
---@param call_opts     table|nil
---@param opts          table|nil { mode = "invoke" | "upload_invoke" }
function M.open(function_name, call_opts, opts)
  opts = opts or {}
  if not valid_function_name(function_name) then
    notify("invalid Lambda function name", vim.log.levels.ERROR)
    return
  end

  if win_valid(state.json_win) and state.function_name == function_name then
    vim.api.nvim_set_current_win(state.json_win)
    if opts.mode then
      M.trigger(opts.mode)
    end
    return
  end

  remember_payload()
  close({ keep_payload = true })
  define_highlights()

  local height = math.max(8, math.min(14, math.floor(vim.o.lines * 0.4)))
  vim.cmd("botright " .. height .. "split")
  local json_win = vim.api.nvim_get_current_win()
  local json_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(json_win, json_buf)
  pcall(vim.api.nvim_buf_set_name, json_buf, "aws://lambda/invoke/" .. function_name)
  vim.bo[json_buf].buftype = "nofile"
  vim.bo[json_buf].bufhidden = "wipe"
  vim.bo[json_buf].swapfile = false
  vim.bo[json_buf].filetype = "json"
  vim.wo[json_win].number = false
  vim.wo[json_win].relativenumber = false
  vim.wo[json_win].signcolumn = "no"
  vim.wo[json_win].winfixheight = true
  vim.wo[json_win].winbar = "%#AwsInvokeButton# AWS Lambda invoke%*  ·  " .. function_name
  local payload = payloads[function_name] or DEFAULT_PAYLOAD
  vim.api.nvim_buf_set_lines(json_buf, 0, -1, false, vim.split(payload, "\n", { plain = true }))
  attach_json_keymaps(json_buf)

  vim.cmd("belowright 1split")
  local bar_win = vim.api.nvim_get_current_win()
  local bar_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(bar_win, bar_buf)
  pcall(vim.api.nvim_buf_set_name, bar_buf, "aws://lambda/invoke/bar")
  vim.bo[bar_buf].buftype = "nofile"
  vim.bo[bar_buf].bufhidden = "wipe"
  vim.bo[bar_buf].swapfile = false
  vim.bo[bar_buf].modifiable = false
  vim.wo[bar_win].number = false
  vim.wo[bar_win].relativenumber = false
  vim.wo[bar_win].cursorline = false
  vim.wo[bar_win].wrap = false
  vim.wo[bar_win].winfixheight = true
  vim.wo[bar_win].winhl = "Normal:AwsInvokeBar"
  vim.wo[bar_win].winbar = ""
  vim.api.nvim_win_set_height(bar_win, 1)
  attach_bar_keymaps(bar_buf)

  state.json_win, state.json_buf = json_win, json_buf
  state.bar_win, state.bar_buf = bar_win, bar_buf
  state.function_name, state.call_opts = function_name, call_opts or {}
  state.status, state.busy, state.last_result = "ready", false, nil
  render_bar()
  vim.api.nvim_set_current_win(json_win)
  vim.api.nvim_win_set_cursor(json_win, { 1, 0 })

  if opts.mode then
    M.trigger(opts.mode)
  end
end

M.state = state

return M
