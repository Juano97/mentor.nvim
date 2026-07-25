local M = {}

---@param cwd string
---@param args string[]
---@return string|nil out, string|nil err
local function git(cwd, args)
  local cmd = vim.list_extend({ "git", "-C", cwd }, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true }):wait(5000)
  end)
  if not ok then
    return nil, "failed to run git: " .. tostring(res)
  end
  if res.code ~= 0 then
    return nil, (res.stderr or ""):gsub("%s+$", "")
  end
  return res.stdout or "", nil
end

--- Once the panel has an input box, the cursor is often *in* the panel when a
--- question is sent. Everything below therefore works off the last real file
--- buffer the user was in, not whatever happens to be focused.
M.last_code_buf = nil

local function is_code_buf(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  return not vim.api.nvim_buf_get_name(buf):match("^mentor://")
end

--- Filetype of a buffer, inferred from the name when detection has not run
--- (a buffer loaded via bufadd()/bufload() has no filetype set).
---@param buf integer
---@return string
local function buf_filetype(buf)
  local ft = vim.bo[buf].filetype
  if ft ~= "" then
    return ft
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return ""
  end
  return vim.filetype.match({ filename = name, buf = buf }) or ""
end

function M.track()
  local buf = vim.api.nvim_get_current_buf()
  if is_code_buf(buf) then
    M.last_code_buf = buf
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("MentorContext", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = M.track,
    desc = "Mentor: remember the last real file buffer",
  })
  M.track()
end

--- The buffer the user is actually working in.
---@return integer|nil
function M.code_buf()
  local cur = vim.api.nvim_get_current_buf()
  if is_code_buf(cur) then
    return cur
  end
  if is_code_buf(M.last_code_buf) then
    return M.last_code_buf
  end
  return nil
end

--- Directory of the working buffer, falling back to cwd.
function M.buf_dir()
  local buf = M.code_buf()
  local name = buf and vim.api.nvim_buf_get_name(buf) or ""
  if name == "" then
    return vim.fn.getcwd()
  end
  return vim.fs.dirname(name)
end

function M.git_root()
  local out = git(M.buf_dir(), { "rev-parse", "--show-toplevel" })
  if not out then
    return nil
  end
  local root = out:gsub("%s+$", "")
  return root ~= "" and root or nil
end

local TARGETS = {
  worktree = { args = { "diff" }, label = "unstaged working-tree changes" },
  staged = { args = { "diff", "--staged" }, label = "staged changes" },
  head = { args = { "diff", "HEAD" }, label = "all changes since HEAD" },
}

--- The diff to review.
---@param cfg table context config
---@return string|nil diff, string label_or_err
function M.recent_changes(cfg)
  local root = M.git_root()
  if not root then
    return nil, "not inside a git repository"
  end

  local target = TARGETS[cfg.diff_target] or TARGETS.worktree
  local out, err = git(root, target.args)
  if not out then
    return nil, err or "git diff failed"
  end

  out = out:gsub("%s+$", "")
  if out == "" then
    -- Nothing unstaged? Fall back to the last commit so the keymap still does
    -- something useful right after a commit.
    local show = git(root, { "show", "--stat", "--patch", "HEAD" })
    if show and show:gsub("%s+$", "") ~= "" then
      return M.truncate(show, cfg.max_diff_lines), "the most recent commit"
    end
    return nil, "no changes to review"
  end

  return M.truncate(out, cfg.max_diff_lines), target.label
end

---@param text string
---@param max_lines integer
function M.truncate(text, max_lines)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines <= max_lines then
    return text
  end
  local kept = vim.list_slice(lines, 1, max_lines)
  table.insert(kept, ("... [truncated %d more lines]"):format(#lines - max_lines))
  return table.concat(kept, "\n")
end

--- Where the user is working, for question context. Nil when there is no real
--- file to talk about (scratch buffer, or only the panel is open).
function M.cursor_context()
  local buf = M.code_buf()
  if not buf then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end

  -- Cursor position from whichever window shows that buffer, if any.
  local line = 1
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      line = vim.api.nvim_win_get_cursor(win)[1]
      break
    end
  end

  local root = M.git_root()
  local path = name
  if root and vim.startswith(name, root .. "/") then
    path = name:sub(#root + 2)
  end

  return { path = path, filetype = buf_filetype(buf), line = line }
end

--- Path of a buffer relative to the repo root, for display.
---@param buf integer
local function rel_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return "[No Name]"
  end
  local root = M.git_root()
  if root and vim.startswith(name, root .. "/") then
    return name:sub(#root + 2)
  end
  return name
end

--- A line-wise slice of the working buffer, for "explain these lines".
---@param first integer
---@param last integer
---@param cfg table|nil context config
---@return table|nil { path, filetype, first, last, text, truncated }
function M.selection(first, last, cfg)
  local buf = M.code_buf()
  if not buf then
    return nil
  end

  local count = vim.api.nvim_buf_line_count(buf)
  first = math.max(1, math.min(first, count))
  last = math.max(first, math.min(last, count))

  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  if #lines == 0 then
    return nil
  end

  local max = (cfg and cfg.max_selection_lines) or 200
  local truncated = false
  if #lines > max then
    lines = vim.list_slice(lines, 1, max)
    last = first + max - 1
    truncated = true
  end

  return {
    path = rel_path(buf),
    filetype = buf_filetype(buf),
    first = first,
    last = last,
    text = table.concat(lines, "\n"),
    truncated = truncated,
  }
end

--- The current visual selection, taken line-wise.
---@param cfg table|nil context config
function M.visual_selection(cfg)
  -- Leave visual mode first so the '< and '> marks are set.
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)

  local buf = vim.api.nvim_get_current_buf()
  local s = vim.api.nvim_buf_get_mark(buf, "<")
  local e = vim.api.nvim_buf_get_mark(buf, ">")
  if s[1] == 0 or e[1] == 0 then
    return nil
  end
  return M.selection(math.min(s[1], e[1]), math.max(s[1], e[1]), cfg)
end

return M
