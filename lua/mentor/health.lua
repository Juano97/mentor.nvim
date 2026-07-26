local M = {}

function M.check()
  local health = vim.health
  local config = require("mentor.config")
  local provider = require("mentor.provider")
  local cfg = config.get()

  health.start("mentor.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ required (vim.system)")
  end

  local impl, name, err = provider.resolve(cfg)
  if not impl then
    health.error("provider: " .. tostring(err))
    return
  end
  health.info(("provider: %s (%s)"):format(name, impl.display_name))

  if name == "claude_cli" then
    if impl.available(cfg.claude_cli) then
      local res = vim.system({ cfg.claude_cli.cmd, "--version" }, { text = true }):wait(5000)
      health.ok(("`%s` found: %s"):format(cfg.claude_cli.cmd, vim.trim(res.stdout or "?")))
      health.info("model: " .. (cfg.claude_cli.model or "the CLI's own default (:MentorModel to change)"))
      health.info("allowed tools: " .. (table.concat(cfg.claude_cli.tools, ", ")))
      health.info("denied tools: " .. table.concat(cfg.claude_cli.disallowed_tools, ", "))
      if not cfg.claude_cli.strict_mcp_config then
        health.warn("strict_mcp_config is off — ambient MCP servers can add tools "
          .. "that bypass the read-only guarantee")
      end
      if cfg.claude_cli.setting_sources ~= "" then
        health.warn("setting_sources is not empty — user/project settings may add tools")
      end
    else
      health.error(("`%s` not found on $PATH"):format(cfg.claude_cli.cmd))
    end
  else
    if vim.fn.executable("curl") == 1 then
      health.ok("`curl` found")
    else
      health.error("`curl` not found on $PATH")
    end
    local key = vim.env[cfg.openai_compat.api_key_env]
    if key and key ~= "" then
      health.ok("$" .. cfg.openai_compat.api_key_env .. " is set")
    else
      health.error("$" .. cfg.openai_compat.api_key_env .. " is not set")
    end
    health.info("endpoint: " .. cfg.openai_compat.base_url)
    health.info("model: " .. cfg.openai_compat.model)
  end

  if vim.fn.executable("git") == 1 then
    health.ok("`git` found (needed for :MentorReview)")
  else
    health.warn("`git` not found — :MentorReview will not work")
  end

  local found = require("mentor.brief").find(cfg.context)
  if cfg.context.project_brief == false then
    health.info("project brief: reading is off (context.project_brief = false)")
  elseif found then
    health.ok("project brief: " .. found.name)
  else
    health.info("project brief: none here — :MentorInit drafts one")
  end
end

return M
