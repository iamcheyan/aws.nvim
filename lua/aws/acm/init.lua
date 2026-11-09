--- aws.nvim – ACM public surface
--- Aggregates the individual submodules into one require-able table.
local M = {}

--- Open the ACM certificates list in a horizontal split.
---@param call_opts AwsCallOpts|nil
function M.list_certificates(call_opts)
  require("aws.acm.certificates").open(call_opts)
end

--- Open the detail view for a certificate by ARN in a vertical split.
---@param arn       string
---@param call_opts AwsCallOpts|nil
function M.open_detail(arn, call_opts)
  require("aws.acm.detail").open(arn, call_opts)
end

return M
