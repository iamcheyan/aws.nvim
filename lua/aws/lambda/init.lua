--- aws.nvim – Lambda public surface
--- Aggregates the individual submodules into one require-able table.
local M = {}

--- Open the Lambda functions list in a horizontal split.
---@param call_opts AwsCallOpts|nil
function M.list_functions(call_opts)
  require("aws.lambda.functions").open(call_opts)
end

--- Open the detail view for a named Lambda function in a vertical split.
---@param fn_name   string
---@param call_opts AwsCallOpts|nil
function M.open_detail(fn_name, call_opts)
  require("aws.lambda.detail").open(fn_name, call_opts)
end

return M
