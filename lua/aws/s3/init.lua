--- aws.nvim – S3 public surface
local M = {}

--- Open the S3 buckets list buffer.
---@param call_opts AwsCallOpts|nil
function M.list_buckets(call_opts)
  require("aws.s3.buckets").open(call_opts)
end

return M
