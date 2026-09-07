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

--- Where :MentorRevision writes: beside the brief it revises, never over it.
---
--- A revision is a document you read against the one you have, so it has to be
--- a second file. `.new` is not in `project_brief_files`, so a draft left lying
--- around is never mistaken for the brief itself.
---@param cfg table context config
---@return string|nil path, string|nil name, table|nil source the brief revised
function M.revision_path(cfg)
  local found = M.find(cfg)
  if not found then
    return nil, nil, nil
  end
  return found.path .. ".new", found.name .. ".new", found
end

--- The brief as it stands, for a revision to work from.
---
--- Whole, unlike `read`: `max_brief_lines` keeps a per-conversation cost down,
--- but a model asked to revise a document it was shown three quarters of would
--- hand back a document with the last quarter deleted. Ignores
--- `project_brief = false` for the same reason `find` does — that switch is
--- about what every conversation carries, not about a revision you asked for.
---@param cfg table context config
---@return table|nil { name, text, path }
function M.read_whole(cfg)
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

  return { name = found.name, text = text, path = found.path }
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

--- Label the draft window. The buffer opens empty, for a file that does not
--- exist, in a split nobody asked for — without a line saying so it reads as a
--- stray buffer you would be right to close. It also carries the one signal the
--- panel cannot: the draft window is not the panel, so the panel's spinner is
--- nowhere near the text you are watching arrive.
---@param win integer|nil
---@param text string empty clears the winbar
local function set_winbar(win, text)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if text == "" then
    vim.wo[win].winbar = ""
    return
  end
  vim.wo[win].winbar = "%#Comment#" .. text:gsub("%%", "%%%%") .. "%*"
end

--- Streaming has started (or is about to).
---@param win integer
---@param name string
function M.mark_drafting(win, name)
  set_winbar(win, ("mentor is writing %s — nothing is on disk yet"):format(name))
end

--- Streaming is over, whether it ran out or `:MentorStop` cut it short; both
--- leave you with the same decision, so both get the same wording.
---@param win integer
---@param name string
function M.mark_done(win, name)
  set_winbar(win, ("mentor stopped writing — `:w` keeps %s, `:q!` discards it"):format(name))
end

--- The same, for a revision, where `:w` is the wrong advice.
---
--- A draft of a file that does not exist is finished by saving it. A revision
--- of a file that does, is not: saving leaves you with two briefs and the merge
--- still to do. What you actually want is the good lines out of it and the file
--- itself gone, so the winbar names `do`/`dp` and offers `:q!` as the ending.
---@param win integer
---@param target string the brief being revised
---@param diffing boolean whether the two are already side by side
function M.mark_merge(win, target, diffing)
  set_winbar(win, diffing
    and ("`do`/`dp` moves a hunk, `:w` in %s keeps it, `:q!` here discards this")
      :format(target)
    or ("mentor stopped writing — `:vert diffsplit %s` to compare, `:q!` discards this")
      :format(target))
end

--- Put the finished revision side by side with the brief it revises.
---
--- `:diffsplit` opens the target in a window of our own, so a window someone
--- already had on the brief keeps its options; the cursor lands in that new
--- window, which is the right end of the diff to be at — `do` pulls a hunk out
--- of the revision and into the file you are keeping, and `:w` there is a save
--- of the real brief, by hand, as it should be.
---@param win integer the revision's window
---@param target_path string the brief being revised
---@return boolean diffing
function M.open_diff(win, target_path)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  vim.api.nvim_set_current_win(win)

  local ok = pcall(vim.cmd, "vertical diffsplit " .. vim.fn.fnameescape(target_path))
  if not ok then
    return false
  end
  local target_win = vim.api.nvim_get_current_win()

  -- Diff mode changes fold and wrap settings, and the window it changed them
  -- in is one we opened. Closing the revision is the end of the comparison, so
  -- it is also the end of diff mode.
  local buf = vim.api.nvim_win_get_buf(win)
  local group = vim.api.nvim_create_augroup("mentor_diff_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufUnload" }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.api.nvim_win_is_valid(target_win) then
        vim.api.nvim_win_call(target_win, function()
          vim.cmd("diffoff")
        end)
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })

  return true
end

--- Nothing but the empty line `bufload` starts with — no model text, no edits
--- of your own.
---@param buf integer
---@return boolean
function M.is_empty(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return #lines == 0 or (#lines == 1 and lines[1] == "")
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

  -- Once you save, the file is real and the advice is wrong; a window reused
  -- for another buffer must not inherit it either.
  local group = vim.api.nvim_create_augroup("mentor_draft_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufWinLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      set_winbar(win, "")
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })

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
