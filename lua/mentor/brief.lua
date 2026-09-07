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
---
--- Two spellings, because a diff of a document is a narrow window. A winbar
--- longer than its window is not shortened, it is *scrolled* — vim shows the
--- tail and hides the front, which is exactly where the key you need is
--- written. So measure first and say less rather than say it off-screen.
---@param win integer
---@param target string the brief being revised
---@param diffing boolean whether the two are already side by side
---@param cmd string|nil the take-everything command, when there is one
function M.mark_merge(win, target, diffing, cmd)
  if not diffing then
    set_winbar(win, ("mentor stopped writing — `:vert diffsplit %s` to compare, `:q!` discards this")
      :format(target))
    return
  end

  -- Longest first; the widest one that fits wins. A diff of a document splits
  -- the screen twice over, so the narrow forms are the ones most people see.
  -- With no take-all command the line names only what `do` can do: `:%diffget`
  -- is not offered as a substitute, because it drops a trailing addition.
  local forms = cmd and {
    ((":%s takes all of it, `do` takes one hunk, `:w` in %s keeps them, `:q!` here discards this")
      :format(cmd, target)),
    ((":%s all · `do` hunk · `:w` %s keeps it · `:q!`"):format(cmd, target)),
    ((":%s all · `do` hunk · `:w` %s · `:q!`"):format(cmd, target)),
    ((":%s all · `do` hunk · `:w` · `:q!`"):format(cmd)),
    ((":%s · do · :w · :q!"):format(cmd)),
  } or {
    ("`do` takes a hunk, `:w` in %s keeps it, `:q!` here discards this"):format(target),
    ("`do` hunk · `:w` %s · `:q!`"):format(target),
    "`do` · `:w` · `:q!`",
  }

  local width = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or 0
  local pick = forms[#forms]
  for _, form in ipairs(forms) do
    if vim.fn.strdisplaywidth(form) <= width then
      pick = form
      break
    end
  end
  set_winbar(win, pick)
end

--- The "all of it" verb, in both halves of the diff.
---
--- `do`/`dp` are for reading a revision hunk by hunk, which is the point of
--- opening one. It is not always what you want: sometimes the new document is
--- simply better and the answer is to take the whole thing. Both buffers get
--- the command so it means the same wherever the cursor is — pull from the
--- brief, push from the revision, and the brief ends up matching either way.
---
--- The lowercase abbreviation exists because `:dg` cannot be a command at all:
--- user commands must start with a capital (E183). Both are buffer-local and
--- both come off with the diff — neither name has any business surviving into
--- ordinary editing.
---
--- Copies the lines rather than running `:%diffget`, which is wrong for this in
--- a way that loses text quietly: `%` is `1,$` in the *current* buffer, so a
--- hunk that only appends past the last line sits outside the range and is
--- skipped. A revision whose only change is a new final paragraph would come
--- across missing exactly that paragraph, with nothing to say so.
---@param buf integer the buffer the command is installed in
---@param name string
---@param from integer buffer to take the text from
---@param to integer buffer to put it in
local function install_take_all(buf, name, from, to)
  vim.api.nvim_buf_create_user_command(buf, name, function()
    if not (vim.api.nvim_buf_is_valid(from) and vim.api.nvim_buf_is_valid(to)) then
      return
    end
    vim.api.nvim_buf_set_lines(to, 0, -1, false, vim.api.nvim_buf_get_lines(from, 0, -1, false))
  end, { desc = "Mentor: take the whole revision" })

  vim.api.nvim_buf_call(buf, function()
    pcall(vim.cmd, ("cnoreabbrev <buffer> %s %s"):format(name:lower(), name))
  end)
end

---@param buf integer
---@param name string
local function remove_take_all(buf, name)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  pcall(vim.api.nvim_buf_del_user_command, buf, name)
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.cmd, "cunabbrev <buffer> " .. name:lower())
  end)
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
---@param cmd string|nil name for the take-everything command, nil for none
---@return boolean diffing
function M.open_diff(win, target_path, cmd)
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
  local target_buf = vim.api.nvim_win_get_buf(target_win)

  -- The same command in both halves, and the same direction in both: taking all
  -- of it means the brief ends up matching the revision, wherever the cursor is.
  if cmd then
    install_take_all(buf, cmd, buf, target_buf)
    install_take_all(target_buf, cmd, buf, target_buf)
  end

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
      if cmd then
        remove_take_all(buf, cmd)
        remove_take_all(target_buf, cmd)
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

  -- `bufadd()` hands back an *unlisted* buffer, which `:ls` does not show. An
  -- unsaved file is exactly the thing a buffer list exists to remind you about,
  -- and a draft you cannot see in it is a draft you cannot find again.
  vim.bo[buf].buflisted = true

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

--- Put a draft that is already open back in front of the user.
---
--- A draft whose window you closed stays loaded, modified and off `:ls` — the
--- only copy of text nothing on disk has. Refusing a second run and describing
--- that buffer was advice about something invisible, so show it instead: reuse
--- its window if it still has one, otherwise split a new one the way
--- `open_draft` does.
---@param buf integer
---@return integer|nil win
function M.show_draft(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      return win
    end
  end

  local host = host_win()
  if host then
    vim.api.nvim_set_current_win(host)
  end
  vim.cmd("split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return win
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
