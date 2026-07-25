local M = {}

M.backends = {
  claude_cli = "mentor.provider.claude_cli",
  openai_compat = "mentor.provider.openai_compat",
}

--- Pick a backend. "auto" prefers the Claude CLI when it is installed, because
--- it costs nothing extra on an existing subscription and gathers its own
--- context; otherwise fall back to the HTTP backend.
---@param cfg table full plugin config
---@return table|nil impl, string|nil name, string|nil err
function M.resolve(cfg)
  local name = cfg.provider

  if name == "auto" then
    local cli = require(M.backends.claude_cli)
    name = cli.available(cfg.claude_cli) and "claude_cli" or "openai_compat"
  end

  local path = M.backends[name]
  if not path then
    return nil, nil, ("unknown provider %q"):format(tostring(name))
  end

  return require(path), name, nil
end

return M
