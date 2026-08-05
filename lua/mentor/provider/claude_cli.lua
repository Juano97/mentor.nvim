--- Backend: the Claude Code CLI in headless mode (`claude -p`).
---
--- Uses whatever auth the user already has, so a Pro/Max subscription means no
--- per-query API cost. The read-only guarantee comes from `--tools` /
--- `--disallowedTools`: the edit tools are absent from the session, so there is
--- nothing for the model to refuse.
local M = {}

M.display_name = "Claude Code CLI"

function M.available(cfg)
  return vim.fn.executable(cfg.cmd) == 1
end

---@param cfg table
---@param system string
---@param state table
---@return string[]
local function build_args(cfg, system, state)
  local args = { "-p", "--output-format", cfg.stream and "stream-json" or "json" }

  if cfg.stream then
    -- stream-json requires --verbose under --print.
    vim.list_extend(args, { "--include-partial-messages", "--verbose" })
  end
  if state.session_id then
    vim.list_extend(args, { "--resume", state.session_id })
  end
  if cfg.model then
    vim.list_extend(args, { "--model", cfg.model })
  end

  -- Allowlist. An empty table means "no tools at all" (pure chat).
  vim.list_extend(args, { "--tools", table.concat(cfg.tools or {}, ",") })

  if cfg.disallowed_tools and #cfg.disallowed_tools > 0 then
    vim.list_extend(args, { "--disallowedTools", table.concat(cfg.disallowed_tools, ",") })
  end
  if cfg.strict_mcp_config then
    table.insert(args, "--strict-mcp-config")
  end
  if cfg.setting_sources ~= nil then
    vim.list_extend(args, { "--setting-sources", cfg.setting_sources })
  end

  local flag = cfg.system_prompt_mode == "replace" and "--system-prompt" or "--append-system-prompt"
  vim.list_extend(args, { flag, system })

  return vim.list_extend(args, cfg.extra_args or {})
end

---@param o table { prompt, system, state, cfg, cwd, on_delta, on_error, on_done }
---@return table|nil handle
function M.chat(o)
  local cfg = o.cfg
  if not M.available(cfg) then
    o.on_error(("`%s` not found on $PATH"):format(cfg.cmd))
    o.on_done()
    return nil
  end

  local cmd = vim.list_extend({ cfg.cmd }, build_args(cfg, o.system, o.state))
  local pending, stderr_chunks = "", {}
  local saw_delta = false
  local reported = false -- the result event already explained the failure

  local function handle_event(ev)
    -- The session id shows up on the init event and again on the result;
    -- keep the freshest one so the next turn can --resume it.
    if ev.session_id then
      o.state.session_id = ev.session_id
    end

    if ev.type == "stream_event" then
      local e = ev.event or {}
      if e.type == "content_block_delta"
        and e.delta
        and e.delta.type == "text_delta"
        and e.delta.text
      then
        saw_delta = true
        o.on_delta(e.delta.text)
      end
    elseif ev.type == "assistant" and not cfg.stream then
      for _, block in ipairs((ev.message or {}).content or {}) do
        if block.type == "text" and block.text then
          saw_delta = true
          o.on_delta(block.text)
        end
      end
    elseif ev.type == "result" then
      if ev.is_error then
        local detail = table.concat(ev.errors or {}, "; ")
        -- A resumed session the CLI no longer has: it prunes its own store, and
        -- a session id from another machine was never there. The id is dead
        -- weight, so drop it — the next question opens a new conversation
        -- instead of failing this way forever. The transcript stays put.
        if detail:find("No conversation found", 1, true) then
          o.state.session_id = nil
          detail = detail .. "\nthe next question starts a new conversation"
        end
        reported = true
        o.on_error(detail ~= "" and detail
          or tostring(ev.result or ev.subtype or "claude reported an error"))
      elseif not saw_delta and type(ev.result) == "string" then
        -- Partial messages never arrived; fall back to the final text.
        o.on_delta(ev.result)
      end
    end
  end

  local handle = vim.system(cmd, {
    text = true,
    cwd = o.cwd,
    stdin = o.prompt, -- avoids ARG_MAX limits on large diffs
    stdout = function(err, data)
      if err or not data then
        return
      end
      pending = pending .. data
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        local line = vim.trim(pending:sub(1, nl - 1))
        pending = pending:sub(nl + 1)
        if line:sub(1, 1) == "{" then
          local ok, ev = pcall(vim.json.decode, line)
          if ok and type(ev) == "table" then
            vim.schedule(function()
              handle_event(ev)
            end)
          end
        end
      end
    end,
    stderr = function(err, data)
      if not err and data and data ~= "" then
        table.insert(stderr_chunks, data)
      end
    end,
  }, function(res)
    vim.schedule(function()
      -- 143 = SIGTERM, i.e. the user cancelled with :MentorStop. A failure the
      -- result event already described does not need saying twice.
      if res.code ~= 0 and res.code ~= 143 and not reported then
        local detail = vim.trim(table.concat(stderr_chunks, ""))
        o.on_error(("claude exited with %d%s"):format(
          res.code, detail ~= "" and ("\n" .. detail) or ""))
      end
      o.on_done()
    end)
  end)

  return handle
end

return M
