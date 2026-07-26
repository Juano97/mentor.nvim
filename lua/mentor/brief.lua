--- The project brief: a Markdown file at the repo root that says what this
--- project is. Read at the start of a conversation so the mentor answers with
--- the project in mind instead of inferring it from one diff.
---
--- The plugin reads the file itself rather than leaving it to the backend, so
--- both providers behave identically.
---
--- `:MentorInit` drafts one when there is none, and the draft lands in an
--- ordinary unsaved buffer — never straight to disk. The model's prose becomes
--- a file only when *you* press `:w`. That is the same bargain todo.lua makes
--- for comment markers: the plugin does the mechanical part, the human decides
--- what is kept.
local context = require("mentor.context")

local M = {}

--- The brief file at the repo root, if there is one.
---
--- Deliberately ignores `project_brief`: reading may be switched off, but
--- :MentorInit still must not clobber a file that is already there.
---@param cfg table context config
---@return table|nil { name, path, root }
function M.find(cfg)
  local root = context.git_root()
  if not root then
    return nil
  end
  for _, name in ipairs(cfg.project_brief_files or {}) do
    local path = root .. "/" .. name
    if vim.fn.filereadable(path) == 1 then
      return { name = name, path = path, root = root }
    end
  end
  return nil
end

--- Contents of the brief, truncated, or nil when there is nothing to send.
---@param cfg table context config
---@return table|nil { name, text }
function M.read(cfg)
  if cfg.project_brief == false then
    return nil
  end
  local found = M.find(cfg)
  if not found then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, found.path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return nil
  end

  return {
    name = found.name,
    text = context.truncate(text, cfg.max_brief_lines or 200),
  }
end

--- Where :MentorInit writes. The first entry of the search list doubles as the
--- write target, so preferring another filename is a one-key change.
---@param cfg table context config
---@return string|nil path, string|nil name
function M.target_path(cfg)
  local root = context.git_root()
  if not root then
    return nil, nil
  end
  local name = (cfg.project_brief_files or {})[1] or "MENTOR.md"
  return root .. "/" .. name, name
end

--- An unsaved draft already open for `path`, if any. Re-running :MentorInit
--- must not wipe a draft you have started editing — the file is not on disk, so
--- the buffer is the only copy.
---@param path string
---@return integer|nil bufnr
function M.pending_draft(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_buf_get_name(buf) == path
      and vim.bo[buf].modified
    then
      return buf
    end
  end
  return nil
end

--- A window to put the draft in — never one of the panel's two, or the draft
--- would open in the sidebar column when :MentorInit is run from the input box.
---@return integer|nil
local function host_win()
  local ui = require("mentor.ui")
  local code = context.code_buf()
  local fallback = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= ui.state.win and win ~= ui.state.input_win then
      if code and vim.api.nvim_win_get_buf(win) == code then
        return win
      end
      fallback = fallback or win
    end
  end
  return fallback
end

--- Open an empty, unsaved buffer at `path` in a split and focus it.
---
--- The file does not exist yet, so the usual editor verbs mean the right thing
--- with no extra machinery: `:w` keeps the draft, `:q!` throws it away.
---@param path string
---@return integer bufnr, integer winid
function M.open_draft(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)

  -- bufadd()/bufload() skips filetype detection (see todo.commentstring).
  if vim.bo[buf].filetype == "" then
    vim.bo[buf].filetype = "markdown"
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

  local host = host_win()
  if host then
    vim.api.nvim_set_current_win(host)
  end
  vim.cmd("split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  return buf, win
end

--- Undo `open_draft` when the request never got off the ground: no empty split
--- and no stale buffer left behind for the next attempt to inherit.
---@param buf integer
---@param win integer
function M.discard_draft(buf, win)
  if win and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- Append a streaming delta to the draft, reassembling mid-line chunks the way
--- the transcript does.
---@param buf integer
---@param text string
function M.append(buf, text)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) or text == nil or text == "" then
    return
  end

  local lines = vim.split(text, "\n", { plain = true })
  local last = vim.api.nvim_buf_line_count(buf)
  local tail = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
  lines[1] = tail .. lines[1]
  vim.api.nvim_buf_set_lines(buf, last - 1, last, false, lines)

  local now = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      -- Tail the draft only while the cursor is still at the end of it; the
      -- moment you scroll up to read, it stops chasing.
      if vim.api.nvim_win_get_cursor(win)[1] >= last then
        pcall(vim.api.nvim_win_set_cursor, win, { now, 0 })
      end
    end
  end
end

return M
