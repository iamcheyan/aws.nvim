local config = require("aws.config")
local keymaps = require("aws.keymaps")

local function actions()
  return setmetatable({}, {
    __index = function()
      return function() end
    end,
  })
end

describe("destructive service keymaps", function()
  before_each(function()
    config.setup({})
  end)

  it("does not install delete or empty actions for any service list", function()
    local appliers = {
      keymaps.apply_cloudformation,
      keymaps.apply_s3,
      keymaps.apply_cloudwatch,
      keymaps.apply_lambda,
      keymaps.apply_acm,
      keymaps.apply_secretsmanager,
      keymaps.apply_dynamodb,
    }

    for _, apply in ipairs(appliers) do
      local buf = vim.api.nvim_create_buf(false, true)
      apply(buf, actions())

      for _, mode in ipairs({ "n", "x" }) do
        for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
          assert.is_not.equals("dd", mapping.lhs)
          assert.is_not.matches("delete", (mapping.desc or ""):lower())
          assert.is_not.matches("empty", (mapping.desc or ""):lower())
        end
      end

      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)
end)
