--- Saved conversations: the transcript you were reading plus whatever the
--- backend needs to pick the thread back up.
---
--- This is the one place the plugin puts the model's prose on disk without you
--- pressing a key. It stays out of the project — `stdpath("state")`, one
--- directory per repo, mode 0600 because a transcript quotes your code — and
--- `history.save = false` turns it off. Writing into the *project* is still
--- yours alone (see brief.lua).
---
--- What resuming actually restores depends on the backend: `claude_cli` keeps
--- one session id and the CLI holds the history in its own store, while
--- `openai_compat` has no server-side session, so its message list is the
--- conversation and is saved in full.
local M = {}

--- Where everything lives. Overridable so a test never touches the real one.
---@param cfg table history config
---@return string
function M.root_dir(cfg)
  return (cfg and cfg.dir) or (vim.fn.stdpath("state") .. "/mentor")
end

--- One directory per repo, named after its path the way the Claude CLI names
--- its own, so `ls` tells you whose conversations these are.
---@param root string
---@return string
local function slug(root)
  return (root:gsub("[^%w]+", "-"):gsub("^%-", ""))
end

---@param cfg table history config
---@param root string repo root
---@return string
function M.dir(cfg, root)
  return M.root_dir(cfg) .. "/" .. slug(root)
end

--- Unique per conversation, and sortable by eye. The random tail is for two
--- nvims starting a conversation in the same second.
---@return string
function M.new_id()
  return ("%s-%04x"):format(os.date("%Y%m%d-%H%M%S"), vim.uv.hrtime() % 0x10000)
end

---@param path string
---@return table|nil conversation
function M.read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines == 0 then
    return nil
  end
  local decoded, conv = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(conv) ~= "table" then
    return nil
  end
  conv.path = path
  return conv
end

--- Saved conversations for a repo, newest first.
---@param cfg table history config
---@param root string
---@return table[]
function M.list(cfg, root)
  local found = {}
  for _, path in ipairs(vim.fn.glob(M.dir(cfg, root) .. "/*.json", true, true)) do
    local conv = M.read(path)
    if conv then
      found[#found + 1] = conv
    end
  end
  table.sort(found, function(a, b)
    return (a.updated or 0) > (b.updated or 0)
  end)
  return found
end

--- Drop everything past `max`, oldest first.
---@param cfg table history config
---@param root string
function M.prune(cfg, root)
  local max = cfg.max or 20
  local saved = M.list(cfg, root)
  for i = max + 1, #saved do
    pcall(vim.fn.delete, saved[i].path)
  end
end

--- Write a conversation out, replacing any earlier version of it.
---@param cfg table history config
---@param conv table the record; `id` and `root` are required
---@return string|nil path nil when saving is off or the write failed
function M.save(cfg, conv)
  if not cfg or cfg.save == false or not (conv.id and conv.root) then
    return nil
  end

  local dir = M.dir(cfg, conv.root)
  vim.fn.mkdir(dir, "p", 448) -- 0700
  local path = dir .. "/" .. conv.id .. ".json"

  -- `path` is where this lives, not part of what it is.
  local record = vim.tbl_extend("force", conv, { path = nil })
  local encoded, json = pcall(vim.json.encode, record)
  if not encoded then
    return nil
  end
  if not pcall(vim.fn.writefile, { json }, path) then
    return nil
  end
  pcall(vim.uv.fs_chmod, path, 384) -- 0600

  M.prune(cfg, conv.root)
  return path
end

---@param path string|nil
function M.forget(path)
  if path then
    pcall(vim.fn.delete, path)
  end
end

--- Unix time, sub-second. Two conversations saved in the same second still
--- have to sort, and asking and re-asking inside one second is ordinary.
---@return number
function M.now()
  local sec, usec = vim.uv.gettimeofday()
  return sec + (usec or 0) / 1e6
end

--- Human wording for the picker. Anything older than a week is a date: "6 days
--- ago" stops meaning much past that point.
---@param ts number|nil unix time
---@return string
function M.ago(ts)
  if not ts then
    return "unknown"
  end
  local d = M.now() - ts
  if d < 60 then
    return "just now"
  elseif d < 3600 then
    return ("%d min ago"):format(math.floor(d / 60))
  elseif d < 86400 then
    return ("%d hours ago"):format(math.floor(d / 3600))
  elseif d < 7 * 86400 then
    return ("%d days ago"):format(math.floor(d / 86400))
  end
  return os.date("%Y-%m-%d", math.floor(ts))
end

--- One line per conversation for `vim.ui.select`.
---@param conv table
---@return string
function M.describe(conv)
  return ("%-12s  %s  (%d turn%s)"):format(
    M.ago(conv.updated),
    conv.title and conv.title ~= "" and conv.title or "(no title)",
    conv.turns or 0,
    (conv.turns or 0) == 1 and "" or "s")
end

return M
