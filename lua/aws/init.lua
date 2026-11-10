--- aws.nvim – public API entry point
local M = {}

--- Configure the plugin. Call once in your Neovim config.
---@param opts AwsConfig|nil
function M.setup(opts)
  require("aws.config").setup(opts)
  require("aws.lambda.workflow").setup_auto_deploy(require("aws.config").values.lambda.auto_deploy)
end

--- CloudFormation operations.
M.cloudformation = require("aws.cloudformation")

--- S3 operations.
M.s3 = require("aws.s3")

--- CloudWatch operations.
M.cloudwatch = require("aws.cloudwatch")

--- AWS profile discovery and switching.
M.profile = require("aws.profile")

--- Unified resource actions (download/upload/invoke/logs/refresh/metadata).
M.resource = require("aws.resource")

--- Upload the AWS resource that backs the current buffer.
M.upload = require("aws.upload")

--- KMS operations.
M.kms = require("aws.kms")

--- Lambda operations.
M.lambda = require("aws.lambda")
M.lambda.workflow = require("aws.lambda.workflow")

--- ACM (Certificate Manager) operations.
M.acm = require("aws.acm")

--- Secrets Manager operations.
M.secretsmanager = require("aws.secretsmanager")

--- CloudFront operations.
M.cloudfront = require("aws.cloudfront")

--- API Gateway operations.
M.apigateway = require("aws.apigateway")

--- ECS (Elastic Container Service) / Fargate operations.
M.ecs = require("aws.ecs")

--- IAM (Identity and Access Management) operations.
M.iam = require("aws.iam")

--- VPC (Virtual Private Cloud) operations.
M.vpc = require("aws.vpc")

--- DynamoDB operations.
M.dynamodb = require("aws.dynamodb")

--- EC2 (Elastic Compute Cloud) operations.
M.ec2 = require("aws.ec2")

--- Open the service picker (snacks.nvim > telescope.nvim > vim.ui.select).
---@param call_opts AwsCallOpts|nil
function M.pick(call_opts)
  require("aws.picker").open(call_opts)
end

return M
