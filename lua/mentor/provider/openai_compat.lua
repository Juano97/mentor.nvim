--- Backend: any OpenAI-compatible /chat/completions endpoint.
---
--- Works with Gemini (via its OpenAI-compatible base URL), Groq, OpenRouter and
--- local Ollama. This backend has no tools at all, so the read-only guarantee
--- is structural here too — there is simply no code path that writes.
local M = {}

M.display_name = "OpenAI-compatible endpoint"

function M.available(_)
  return vim.fn.executable("curl") == 1
end

--- Put the headers in a file only we can read, for curl's `-H @file`.
---
--- They carry the API key, and argv is public: any local user can read it out
--- of `ps` or `/proc/<pid>/cmdline` for as long as the request runs. Stdin is
--- already the request body, so a file it is — created 0600 with O_EXCL, so it
--- is never readable by anyone else even for a moment and never someone else's
--- file. CR/LF are stripped so a value cannot smuggle in a header of its own.
---@param headers string[]
---@return string|nil path, string|nil err
function M.write_headers(headers)
  local path = vim.fn.tempname()
  local fd, err = vim.uv.fs_open(path, "wx", 384) -- 0600
  if not fd then
    return nil, err
  end
  local lines = {}
  for _, h in ipairs(headers) do
    lines[#lines + 1] = (h:gsub("[\r\n]", ""))
  end
  local ok, werr = vim.uv.fs_write(fd, table.concat(lines, "\n") .. "\n")
  vim.uv.fs_close(fd)
  if not ok then
    pcall(vim.uv.fs_unlink, path)
    return nil, werr
  end
  return path, nil
end

---@param o table { prompt, system, state, cfg, cwd, on_delta, on_error, on_done }
---@return table|nil handle
function M.chat(o)
  local cfg = o.cfg

  if not M.available(cfg) then
    o.on_error("`curl` not found on $PATH")
    o.on_done()
    return nil
  end

  local key = vim.env[cfg.api_key_env]
  if not key or key == "" then
    o.on_error(("$%s is not set"):format(cfg.api_key_env))
    o.on_done()
    return nil
  end

  o.state.messages = o.state.messages or {}
  table.insert(o.state.messages, { role = "user", content = o.prompt })

  local messages = { { role = "system", content = o.system } }
  vim.list_extend(messages, o.state.messages)

  local body = vim.json.encode({
    model = cfg.model,
    stream = cfg.stream and true or false,
    max_tokens = cfg.max_tokens,
    messages = messages,
  })

  local headers = { "Authorization: Bearer " .. key }
  for header, value in pairs(cfg.extra_headers or {}) do
    headers[#headers + 1] = header .. ": " .. value
  end
  local header_file, herr = M.write_headers(headers)
  if not header_file then
    o.on_error("could not write the request headers: " .. tostring(herr))
    o.on_done()
    return nil
  end

  local cmd = {
    "curl", "-sS", "-N", "-X", "POST",
    cfg.base_url .. "/chat/completions",
    "-H", "Content-Type: application/json",
    "-H", "@" .. header_file,
    "--data-binary", "@-",
  }

  local pending, raw = "", {}
  local reply = {}

  local function emit(text)
    if text and text ~= "" then
      table.insert(reply, text)
      o.on_delta(text)
    end
  end

  local function handle_sse_line(line)
    if not vim.startswith(line, "data:") then
      return
    end
    local payload = vim.trim(line:sub(6))
    if payload == "" or payload == "[DONE]" then
      return
    end
    local ok, chunk = pcall(vim.json.decode, payload)
    if not ok or type(chunk) ~= "table" then
      return
    end
    if chunk.error then
      o.on_error(tostring(chunk.error.message or vim.inspect(chunk.error)))
      return
    end
    local choice = (chunk.choices or {})[1]
    if choice and choice.delta then
      emit(choice.delta.content)
    end
  end

  local handle = vim.system(cmd, {
    text = true,
    cwd = o.cwd,
    stdin = body,
    stdout = function(err, data)
      if err or not data then
        return
      end
      if not cfg.stream then
        table.insert(raw, data)
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
        if line ~= "" then
          vim.schedule(function()
            handle_sse_line(line)
          end)
        end
      end
    end,
    stderr = function(err, data)
      if not err and data and data ~= "" then
        table.insert(raw, data)
      end
    end,
  }, function(res)
    -- curl read the file at startup; the key has no reason to outlive the
    -- request. (Were this ever missed, it sits in nvim's own tempdir, which is
    -- private to you and removed when nvim exits.)
    pcall(vim.uv.fs_unlink, header_file)
    vim.schedule(function()
      if not cfg.stream and res.code == 0 then
        local ok, decoded = pcall(vim.json.decode, table.concat(raw, ""))
        if ok and type(decoded) == "table" then
          if decoded.error then
            o.on_error(tostring(decoded.error.message or "request failed"))
          else
            local choice = (decoded.choices or {})[1]
            emit(choice and choice.message and choice.message.content)
          end
        else
          o.on_error("could not parse response")
        end
      elseif res.code ~= 0 and res.code ~= 143 then
        o.on_error(("curl exited with %d\n%s"):format(res.code, vim.trim(table.concat(raw, ""))))
      end

      local text = table.concat(reply)
      if text ~= "" then
        table.insert(o.state.messages, { role = "assistant", content = text })
      end
      o.on_done()
    end)
  end)

  return handle
end

return M
