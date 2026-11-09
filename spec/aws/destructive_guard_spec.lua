local config = require("aws.config")
local spawn = require("aws.spawn")

describe("remote deletion safety", function()
  before_each(function()
    config.setup({})
  end)

  it("blocks AWS delete operations before creating a subprocess", function()
    local original_spawn = vim.loop.spawn
    vim.loop.spawn = function()
      error("delete operation reached subprocess")
    end

    local result
    spawn.run({ "lambda", "delete-function", "--function-name", "sample" }, function(ok, lines)
      result = { ok = ok, lines = lines }
    end)

    vim.wait(1000, function()
      return result ~= nil
    end, 10)
    vim.loop.spawn = original_spawn

    assert.is_false(result.ok)
    assert.equals("Remote delete operations are disabled", result.lines[1])
  end)

  it("blocks S3 object deletion payloads", function()
    local original_spawn = vim.loop.spawn
    vim.loop.spawn = function()
      error("S3 delete operation reached subprocess")
    end

    local result
    spawn.run({ "s3api", "delete-objects", "--delete", "{}" }, function(ok, lines)
      result = { ok = ok, lines = lines }
    end)

    vim.wait(1000, function()
      return result ~= nil
    end, 10)
    vim.loop.spawn = original_spawn

    assert.is_false(result.ok)
    assert.equals("Remote delete operations are disabled", result.lines[1])
  end)
end)
