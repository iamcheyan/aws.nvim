-- Interactive Lambda invoke panel: layout, buttons, and key handling.
local config = require("aws.config")
local ui = require("aws.lambda.invoke_ui")
local workflow = require("aws.lambda.workflow")

local function open_panel(name)
  ui.open(name or "payments-api", { region = "ap-northeast-1" })
  local st = ui.inspect()
  assert.is_true(st.open, "invoke panel should be open")
  return st
end

describe("Lambda invoke panel", function()
  before_each(function()
    config.setup({})
  end)

  after_each(function()
    ui.close()
  end)

  it("opens a horizontal split pinned to the bottom with a JSON box and a button bar", function()
    local st = open_panel()
    local json_win, bar_win = st.json_win, st.bar_win

    assert.is_true(vim.api.nvim_win_is_valid(json_win))
    assert.is_true(vim.api.nvim_win_is_valid(bar_win))

    local json_pos = vim.api.nvim_win_get_position(json_win)
    local bar_pos = vim.api.nvim_win_get_position(bar_win)
    local json_height = vim.api.nvim_win_get_height(json_win)
    local bar_height = vim.api.nvim_win_get_height(bar_win)

    -- stacked horizontally: the button bar sits directly below the JSON box
    assert.equals(json_pos[2], bar_pos[2])
    assert.equals(json_pos[1] + json_height + 1, bar_pos[1])
    assert.equals(1, bar_height)
    assert.equals(vim.api.nvim_win_get_width(json_win), vim.api.nvim_win_get_width(bar_win))

    -- the panel is a bottom split: every other window sits above it
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= json_win and win ~= bar_win then
        assert.is_true(vim.api.nvim_win_get_position(win)[1] < json_pos[1])
      end
    end
    assert.equals("", vim.api.nvim_win_get_config(json_win).relative)
    assert.equals("", vim.api.nvim_win_get_config(bar_win).relative)

    -- the JSON box is a real editable buffer named after the function
    assert.equals("json", vim.bo[st.json_buf].filetype)
    assert.is_true(vim.bo[st.json_buf].modifiable)
    assert.equals("aws://lambda/invoke/payments-api", vim.api.nvim_buf_get_name(st.json_buf))
    local payload = vim.api.nvim_buf_get_lines(st.json_buf, 0, -1, false)
    assert.is_true(vim.json.decode(table.concat(payload, "\n")) ~= nil)
  end)

  it("renders clickable buttons with the expected labels", function()
    local st = open_panel()
    local bar = vim.api.nvim_buf_get_lines(st.bar_buf, 0, -1, false)[1]

    assert.is_truthy(bar:find("[ Invoke", 1, true))
    assert.is_truthy(bar:find("[ Upload + Invoke ]", 1, true))
    assert.is_truthy(bar:find("[ Copy response ]", 1, true))
    assert.is_truthy(bar:find("[ Close", 1, true))
    assert.is_truthy(bar:find("payments-api", 1, true))

    -- every rendered button maps back to an action by its clickable column
    local ids = {}
    for _, span in ipairs(st.buttons) do
      ids[span.id] = ui.button_at(span.start + 3)
    end
    assert.equals("invoke", ids.invoke)
    assert.equals("upload_invoke", ids.upload_invoke)
    assert.equals("copy", ids.copy)
    assert.equals("close", ids.close)
    assert.is_nil(ui.button_at(#bar + 5))

    local maps = vim.api.nvim_buf_get_keymap(st.bar_buf, "n")
    local lhs = vim.tbl_map(function(m)
      return m.lhs
    end, maps)
    assert.is_true(vim.tbl_contains(lhs, "<LeftMouse>"))
    assert.is_true(vim.tbl_contains(lhs, "<CR>"))
  end)

  it("invokes the function with the edited JSON payload on <C-s>", function()
    local root = vim.fn.tempname()
    local dir = root .. "/lambda/payments-api"
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(
      vim.split(vim.json.encode({ function_name = "payments-api", region = "ap-northeast-1" }), "\n"),
      dir .. "/.aws-meta.json"
    )
    vim.fn.writefile({ "{}" }, dir .. "/invoke.json")
    local old_cwd = vim.fn.getcwd()
    vim.cmd.cd(root)

    local st = open_panel()
    vim.api.nvim_buf_set_lines(st.json_buf, 0, -1, false, { '{"order":"42"}' })

    local captured = {}
    local original = workflow.invoke_file
    workflow.invoke_file = function(invoke_dir, function_name, call_opts, callback)
      table.insert(captured, {
        dir = invoke_dir,
        function_name = function_name,
        call_opts = call_opts,
        payload = table.concat(vim.fn.readfile(invoke_dir .. "/invoke.json"), "\n"),
      })
      vim.schedule(function()
        callback({ ok = true, status = 200, response = '{"ok":true}', logs = "START RequestId: req-1" })
      end)
    end

    vim.api.nvim_set_current_win(st.json_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
    assert.is_true(vim.wait(2000, function()
      return ui.inspect().last_result ~= nil
    end))

    workflow.invoke_file = original

    assert.equals(1, #captured)
    assert.equals("payments-api", captured[1].function_name)
    assert.equals(dir, captured[1].dir)
    assert.equals('{"order":"42"}', captured[1].payload)
    assert.equals("ap-northeast-1", captured[1].call_opts.region)
    assert.equals("ok · 200", ui.inspect().status)

    local result_buf = vim.fn.bufnr("aws://lambda/invoke-result/payments-api")
    assert.is_true(result_buf > 0)
    local result_text = table.concat(vim.api.nvim_buf_get_lines(result_buf, 0, -1, false), "\n")
    assert.is_truthy(result_text:find('"ok":true', 1, true))
    assert.is_truthy(result_text:find("START RequestId: req-1", 1, true))

    vim.cmd.cd(old_cwd)
    vim.fn.delete(root, "rf")
  end)

  it("keeps the panel open and reports invalid JSON without calling AWS", function()
    local st = open_panel()
    vim.api.nvim_buf_set_lines(st.json_buf, 0, -1, false, { "{ not json" })

    local original = workflow.invoke_payload
    local calls = 0
    workflow.invoke_payload = function()
      calls = calls + 1
    end

    ui.trigger("invoke")
    workflow.invoke_payload = original

    assert.equals(0, calls)
    assert.equals("invalid JSON", ui.inspect().status)
    assert.is_true(ui.inspect().open)
  end)

  it("remembers the payload when the panel is reopened", function()
    local st = open_panel()
    vim.api.nvim_buf_set_lines(st.json_buf, 0, -1, false, { '{"kept":true}' })
    ui.close()

    local reopened = open_panel()
    local lines = vim.api.nvim_buf_get_lines(reopened.json_buf, 0, -1, false)
    assert.equals('{"kept":true}', table.concat(lines, "\n"))
  end)

  it("replaces an existing panel instead of stacking splits", function()
    open_panel("payments-api")
    local first_wins = #vim.api.nvim_tabpage_list_wins(0)
    open_panel("orders-api")
    local second_wins = #vim.api.nvim_tabpage_list_wins(0)

    assert.equals(first_wins, second_wins)
    assert.equals("orders-api", ui.inspect().function_name)
  end)
end)
