--- aws.nvim – plugin entry point
--- Registers user commands. Loaded automatically by Neovim's plugin system.

if vim.g.loaded_aws_nvim then return end
vim.g.loaded_aws_nvim = true

if vim.fn.has("nvim-0.9") == 0 then
  vim.notify("aws.nvim requires Neovim >= 0.9", vim.log.levels.ERROR)
  return
end

local aws = require("aws")

-------------------------------------------------------------------------------
-- Flag parser
-- Extracts --region <value> and --profile <value> from fargs, returns the
-- remaining positional args plus a call_opts table (or nil when neither flag
-- was present).
-------------------------------------------------------------------------------

---@param fargs string[]
---@return string[], AwsCallOpts|nil, boolean
local function parse_flags(fargs)
  local positional = {}
  local opts = {}
  local fresh = false
  local i = 1
  while i <= #fargs do
    local arg = fargs[i]
    if arg == "--region" and fargs[i + 1] then
      opts.region = fargs[i + 1]
      i = i + 2
    elseif arg == "--profile" and fargs[i + 1] then
      opts.profile = fargs[i + 1]
      i = i + 2
    elseif arg == "--fresh" then
      fresh = true
      i = i + 1
    else
      table.insert(positional, arg)
      i = i + 1
    end
  end
  local call_opts = (opts.region or opts.profile) and opts or nil
  return positional, call_opts, fresh
end

-------------------------------------------------------------------------------
-- :AwsCF [--region <r>] [--profile <p>] [subcommand [name]]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsCF", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub  = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local name = args[2]

  if sub == "list" or sub == "ls" then
    aws.cloudformation.list_stacks(call_opts)

  elseif sub == "events" then
    if not name or name == "" then
      vim.notify("Usage: :AwsCF events <stack-name>", vim.log.levels.WARN)
      return
    end
    aws.cloudformation.stack_events(name, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, events <name>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: CloudFormation operations",
  complete = function(arglead, cmdline, _)
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    -- offer flag completions when the lead starts with -
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    -- offer sub-command completions for the first positional word
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "events" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsS3 [--region <r>] [--profile <p>] [subcommand [name]]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsS3", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub  = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end

  if sub == "list" or sub == "ls" then
    aws.s3.list_buckets(call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: S3 operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsCW [--region <r>] [--profile <p>] [subcommand [name [stream]]]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsCW", function(opts)
  local args, call_opts, fresh = parse_flags(opts.fargs)
  local sub    = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local name   = args[2]
  local stream = args[3]

  if sub == "list" or sub == "ls" then
    aws.cloudwatch.list_groups(call_opts, fresh)

  elseif sub == "streams" then
    if not name or name == "" then
      vim.notify("Usage: :AwsCW streams <log-group-name>", vim.log.levels.WARN)
      return
    end
    aws.cloudwatch.list_streams(name, call_opts)

  elseif sub == "logs" then
    if not name or name == "" or not stream or stream == "" then
      vim.notify("Usage: :AwsCW logs <log-group-name> <stream-name>", vim.log.levels.WARN)
      return
    end
    aws.cloudwatch.list_logs(name, stream, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, streams <group>, logs <group> <stream>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: CloudWatch operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile", "--fresh" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "streams", "logs" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsLambda [--region <r>] [--profile <p>] [subcommand [name]]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsLambda", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub  = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local name = args[2]

  if sub == "list" or sub == "ls" then
    aws.lambda.list_functions(call_opts)

  elseif sub == "detail" then
    if not name or name == "" then
      vim.notify("Usage: :AwsLambda detail <function-name>", vim.log.levels.WARN)
      return
    end
    aws.lambda.open_detail(name, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, detail <name>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: Lambda operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "detail" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsACM [--region <r>] [--profile <p>] [subcommand [arn]]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsACM", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local arn = args[2]

  if sub == "list" or sub == "ls" then
    aws.acm.list_certificates(call_opts)

  elseif sub == "detail" then
    if not arn or arn == "" then
      vim.notify("Usage: :AwsACM detail <certificate-arn>", vim.log.levels.WARN)
      return
    end
    aws.acm.open_detail(arn, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, detail <arn>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: ACM (Certificate Manager) operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "detail" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsSM [--region <r>] [--profile <p>] [subcommand [name]]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsSM", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub  = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local name = args[2]

  if sub == "list" or sub == "ls" then
    aws.secretsmanager.list_secrets(call_opts)

  elseif sub == "detail" then
    if not name or name == "" then
      vim.notify("Usage: :AwsSM detail <secret-name>", vim.log.levels.WARN)
      return
    end
    aws.secretsmanager.open_detail(name, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, detail <name>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: Secrets Manager operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "detail" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsAGW [--region <r>] [--profile <p>] [subcommand [id]]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsAGW", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local id  = args[2]

  if sub == "list" or sub == "ls" then
    aws.apigateway.list_apis(call_opts)

  elseif sub == "detail" then
    if not id or id == "" then
      vim.notify("Usage: :AwsAGW detail <rest-api-id>", vim.log.levels.WARN)
      return
    end
    aws.apigateway.open_detail(id, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, detail <id>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: API Gateway operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "detail" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsCFront [--region <r>] [--profile <p>] [subcommand [id]]
------------------------------------------------------------------------------------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsCFront", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local id  = args[2]

  if sub == "list" or sub == "ls" then
    aws.cloudfront.list_distributions(call_opts)

  elseif sub == "detail" then
    if not id or id == "" then
      vim.notify("Usage: :AwsCFront detail <distribution-id>", vim.log.levels.WARN)
      return
    end
    aws.cloudfront.open_detail(id, call_opts)

  elseif sub == "invalidate" or sub == "inv" then
    if not id or id == "" then
      vim.notify("Usage: :AwsCFront invalidate <distribution-id>", vim.log.levels.WARN)
      return
    end
    aws.cloudfront.invalidate(id, nil, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, detail <id>, invalidate <id>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: CloudFront operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "detail", "invalidate" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsECS [--region <r>] [--profile <p>] [subcommand [cluster-arn]]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsECS", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local arn = args[2]

  if sub == "list" or sub == "ls" then
    aws.ecs.list_clusters(call_opts)

  elseif sub == "detail" then
    if not arn or arn == "" then
      vim.notify("Usage: :AwsECS detail <cluster-arn-or-name>", vim.log.levels.WARN)
      return
    end
    aws.ecs.open_detail(arn, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, detail <cluster-arn>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: ECS / Fargate operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "detail" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsIAM [--region <r>] [--profile <p>] [subcommand [arg [kind]]]
-- subcommands: list/ls, users, groups, roles, policies, providers
--              detail user <name>
--              detail group <name>
--              detail role <name>
--              detail policy <arn>
--              detail provider <arn> <oidc|saml>
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsIAM", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub  = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end

  if sub == "list" or sub == "ls" then
    aws.iam.open_menu(call_opts)

  elseif sub == "users" then
    aws.iam.list_users(call_opts)

  elseif sub == "groups" then
    aws.iam.list_groups(call_opts)

  elseif sub == "roles" then
    aws.iam.list_roles(call_opts)

  elseif sub == "policies" then
    aws.iam.list_policies(call_opts)

  elseif sub == "providers" then
    aws.iam.list_providers(call_opts)

  elseif sub == "detail" then
    local kind = args[2]
    local name = args[3]
    if not kind or kind == "" then
      vim.notify(
        "Usage: :AwsIAM detail <user|group|role|policy|provider> <name-or-arn> [oidc|saml]",
        vim.log.levels.WARN
      )
      return
    end
    if not name or name == "" then
      vim.notify("Usage: :AwsIAM detail " .. kind .. " <name-or-arn>", vim.log.levels.WARN)
      return
    end

    if kind == "user" then
      aws.iam.open_user(name, call_opts)
    elseif kind == "group" then
      aws.iam.open_group(name, call_opts)
    elseif kind == "role" then
      aws.iam.open_role(name, call_opts)
    elseif kind == "policy" then
      aws.iam.open_policy(name, call_opts)
    elseif kind == "provider" then
      local provider_kind = args[4] or "oidc"
      aws.iam.open_provider(name, provider_kind, call_opts)
    else
      vim.notify(
        "aws.nvim: unknown detail type '" .. kind .. "'\n"
          .. "Available: user, group, role, policy, provider",
        vim.log.levels.WARN
      )
    end

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, users, groups, roles, policies, providers, detail <type> <name>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: IAM operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local out = {}
      for _, f in ipairs({ "--region", "--profile" }) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional = {}
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then table.insert(positional, p) end
    end
    local npos = #positional
    local trailing_space = cmdline:match("%s$")

    -- first positional: sub-command
    if npos <= 1 or (npos == 2 and not trailing_space) then
      local subs = { "list", "users", "groups", "roles", "policies", "providers", "detail" }
      local out = {}
      for _, s in ipairs(subs) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end

    -- second positional (only when sub == "detail"): detail type
    if positional[2] == "detail" then
      if npos == 2 or (npos == 3 and not trailing_space) then
        local types = { "user", "group", "role", "policy", "provider" }
        local out = {}
        for _, t in ipairs(types) do
          if t:find(arglead, 1, true) == 1 then table.insert(out, t) end
        end
        return out
      end
      -- fourth positional (only for provider): oidc|saml
      if positional[2] == "detail" and positional[3] == "provider" then
        if npos == 4 or (npos == 5 and not trailing_space) then
          local out = {}
          for _, k in ipairs({ "oidc", "saml" }) do
            if k:find(arglead, 1, true) == 1 then table.insert(out, k) end
          end
          return out
        end
      end
    end

    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsVPC [--region <r>] [--profile <p>] [subcommand [vpc-id]]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsVPC", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local id  = args[2]

  if sub == "list" or sub == "ls" then
    aws.vpc.list_vpcs(call_opts)

  elseif sub == "detail" then
    if not id or id == "" then
      vim.notify("Usage: :AwsVPC detail <vpc-id>", vim.log.levels.WARN)
      return
    end
    aws.vpc.open_detail(id, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, detail <vpc-id>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: VPC operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local flags = { "--region", "--profile" }
      local out = {}
      for _, f in ipairs(flags) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "detail" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsDDB [--region <r>] [--profile <p>] [subcommand [table-name]]
-- subcommands: list/ls, menu <name>, detail <name>, scan <name>
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsDDB", function(opts)
  local args, call_opts = parse_flags(opts.fargs)
  local sub  = args[1] or "list"
  if sub == "delete" or sub == "del" or sub == "empty" then
    vim.notify("aws.nvim: remote delete operations are disabled", vim.log.levels.WARN)
    return
  end
  local name = args[2]

  if sub == "list" or sub == "ls" then
    aws.dynamodb.list_tables(call_opts)

  elseif sub == "menu" then
    if not name or name == "" then
      vim.notify("Usage: :AwsDDB menu <table-name>", vim.log.levels.WARN)
      return
    end
    aws.dynamodb.open_menu(name, call_opts)

  elseif sub == "detail" then
    if not name or name == "" then
      vim.notify("Usage: :AwsDDB detail <table-name>", vim.log.levels.WARN)
      return
    end
    aws.dynamodb.open_detail(name, call_opts)

  elseif sub == "scan" then
    if not name or name == "" then
      vim.notify("Usage: :AwsDDB scan <table-name>", vim.log.levels.WARN)
      return
    end
    aws.dynamodb.open_scan(name, call_opts)

  else
    vim.notify(
      "aws.nvim: unknown sub-command '" .. sub .. "'\n"
        .. "Available: list, menu <name>, detail <name>, scan <name>",
      vim.log.levels.WARN
    )
  end
end, {
  nargs = "*",
  desc  = "aws.nvim: DynamoDB operations",
  complete = function(arglead, cmdline, _)
    if arglead:sub(1, 1) == "-" then
      local out = {}
      for _, f in ipairs({ "--region", "--profile" }) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    local parts = vim.split(cmdline, "%s+", { trimempty = true })
    local positional_count = 0
    for _, p in ipairs(parts) do
      if p:sub(1, 1) ~= "-" then positional_count = positional_count + 1 end
    end
    if positional_count <= 1 or (positional_count == 2 and not cmdline:match("%s$")) then
      local out = {}
      for _, s in ipairs({ "list", "menu", "detail", "scan" }) do
        if s:find(arglead, 1, true) == 1 then table.insert(out, s) end
      end
      return out
    end
    return {}
  end,
})

-------------------------------------------------------------------------------
-- :AwsEC2 [--region <r>] [--profile <p>]
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsEC2", function(opts)
  local _, call_opts = parse_flags(opts.fargs)
  aws.ec2.list_instances(call_opts)
end, {
  nargs = "*",
  desc = "aws.nvim: list EC2 instances",
  complete = function(arglead)
    if arglead:sub(1, 1) ~= "-" then return {} end
    local out = {}
    for _, flag in ipairs({ "--region", "--profile" }) do
      if flag:find(arglead, 1, true) == 1 then table.insert(out, flag) end
    end
    return out
  end,
})

-------------------------------------------------------------------------------
-- :AwsPicker [--region <r>] [--profile <p>]
-- Opens a fuzzy service picker (snacks > telescope > vim.ui.select).
-------------------------------------------------------------------------------

vim.api.nvim_create_user_command("AwsPicker", function(opts)
  local _, call_opts = parse_flags(opts.fargs)
  aws.pick(call_opts)
end, {
  nargs = "*",
  desc  = "aws.nvim: open service picker",
  complete = function(arglead, _, _)
    if arglead:sub(1, 1) == "-" then
      local out = {}
      for _, f in ipairs({ "--region", "--profile" }) do
        if f:find(arglead, 1, true) == 1 then table.insert(out, f) end
      end
      return out
    end
    return {}
  end,
})

local workflow = require("aws.lambda.workflow")

local function lambda_workflow_command(name, desc, action)
  vim.api.nvim_create_user_command(name, function(opts)
    local _, call_opts = parse_flags(opts.fargs)
    action(call_opts)
  end, {
    nargs = "*",
    desc = "aws.nvim: " .. desc,
    complete = function(arglead)
      if arglead:sub(1, 1) ~= "-" then return {} end
      local out = {}
      for _, flag in ipairs({ "--region", "--profile" }) do
        if flag:find(arglead, 1, true) == 1 then table.insert(out, flag) end
      end
      return out
    end,
  })
end

lambda_workflow_command("AwsUpload", "upload the AWS resource behind the current buffer", function(opts)
  require("aws.upload").upload(opts)
end)

lambda_workflow_command("AwsLambdaUpload", "upload bound Lambda source", function(opts)
  workflow.upload_current(opts)
end)
lambda_workflow_command("AwsLambdaInvoke", "invoke bound Lambda", function(opts)
  workflow.invoke_current(opts)
end)
lambda_workflow_command("AwsLambdaUploadInvoke", "upload and invoke bound Lambda", function(opts)
  workflow.upload_and_invoke(opts)
end)
lambda_workflow_command("AwsLambdaLogs", "follow bound Lambda logs", function(opts)
  workflow.tail_logs(opts)
end)

vim.api.nvim_create_user_command("AwsLambdaLogsStop", function()
  workflow.stop_logs()
end, { desc = "aws.nvim: stop live Lambda logs" })
