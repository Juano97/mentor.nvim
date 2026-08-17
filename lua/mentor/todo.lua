--- TODO(human) markers, in the spirit of Claude Code's Learning output style.
---
--- The model never writes anything: it proposes structured items in the panel,
--- and *this* module inserts a comment line into your buffer when you ask it
--- to. The inserted text is a comment built by Lua from the item's one-line
--- description — never model-authored code. That keeps the read-only guarantee
--- intact while still giving you the marker to work against.
local context = require("mentor.context")

local M = {}

--- Parse "- `path/to/file.py:42` — do the thing" out of the panel.
---@param line string
---@return table|nil { path, line, text }
function M.parse_line(line)
  local stripped = line:gsub("`", "")
  local path, lnum, rest = stripped:match("^%s*[%-%*]%s+([^:%s]+):(%d+)(.*)$")
  if not path or not rest then
    return nil
  end
  -- Strip the separator, which may be "-", ":" or a multibyte em dash.
  local text = rest:gsub("^[^%w]*", "")
  if text == "" then
    return nil
  end
  return { path = path, line = tonumber(lnum), text = text }
end

---@param bufnr integer panel buffer
---@return table[] items each with an extra `panel_line`
function M.parse_buffer(bufnr)
  local items = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local item = M.parse_line(line)
    if item then
      item.panel_line = i
      table.insert(items, item)
    end
  end
  return items
end

--- Items from the last TODO section only, so re-running does not replay
--- everything from earlier in the conversation.
---@param bufnr integer
function M.parse_last_block(bufnr)
  local items = M.parse_buffer(bufnr)
  if #items == 0 then
    return items
  end
  local block = { items[#items] }
  for i = #items - 1, 1, -1 do
    -- Contiguous list items belong to the same block.
    if items[i].panel_line >= block[1].panel_line - 2 then
      table.insert(block, 1, items[i])
    else
      break
    end
  end
  return block
end

--- Resolve the comment syntax for a buffer.
---
--- `bufadd()` + `bufload()` loads a file without running filetype detection, so
--- 'commentstring' is empty for any file the user does not already have open.
--- Blindly falling back to "# %s" would write a Python comment into a Lua or JS
--- file, so force detection first and only guess as a last resort.
---@param buf integer
---@return string
function M.commentstring(buf)
  local cs = vim.bo[buf].commentstring
  if cs ~= nil and cs ~= "" then
    return cs
  end

  pcall(function()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("filetype detect")
    end)
  end)
  cs = vim.bo[buf].commentstring
  if cs ~= nil and cs ~= "" then
    return cs
  end

  -- Detection is disabled or the file is unrecognised: infer from the name.
  local ft = vim.filetype.match({ filename = vim.api.nvim_buf_get_name(buf), buf = buf })
  local by_ft = {
    lua = "-- %s",
    sql = "-- %s",
    haskell = "-- %s",
    c = "// %s", cpp = "// %s", java = "// %s", rust = "// %s", go = "// %s",
    javascript = "// %s", typescript = "// %s", javascriptreact = "// %s",
    typescriptreact = "// %s", php = "// %s", zig = "// %s", scala = "// %s",
    css = "/* %s */",
    html = "<!-- %s -->", xml = "<!-- %s -->", markdown = "<!-- %s -->",
    vim = '" %s',
    lisp = "; %s", clojure = "; %s",
  }
  return by_ft[ft] or "# %s"
end

---@param item table { path, line, text }
---@return boolean ok, string message
function M.insert(item)
  local root = context.git_root() or vim.fn.getcwd()
  local path = item.path
  if not vim.startswith(path, "/") then
    path = root .. "/" .. path
  end

  if vim.fn.filereadable(path) == 0 then
    return false, "no such file: " .. item.path
  end

  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)

  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    return false, item.path .. " is not modifiable"
  end

  local count = vim.api.nvim_buf_line_count(buf)
  local lnum = math.min(math.max(item.line or 1, 1), count)

  local target = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local indent = target:match("^%s*") or ""

  local marker = require("mentor.config").get().learning.marker
  local body = marker .. ": " .. item.text
  local cs = M.commentstring(buf)
  -- Function replacement: item.text may contain % which breaks a plain gsub.
  local comment = cs:gsub("%%s", function()
    return body
  end)

  vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum - 1, false, { indent .. comment })
  return true, ("%s:%d"):format(item.path, lnum)
end

--- Is this line a marker comment of the shape `insert()` writes?
---
--- Whole-line comment, the marker first in the body, and the colon that
--- `insert()` puts after it. The colon is what keeps prose that merely mentions
--- TODO(human) — a README line, a docstring — out of the sweep, and requiring
--- the comment to be the whole line keeps a marker appended after real code
--- (yours, not ours) from taking the code with it.
---@param line string
---@param cs string commentstring for the buffer the line came from
---@param marker string
---@return boolean
function M.is_marker(line, cs, marker)
  local prefix, suffix = cs:match("^(.-)%%s(.*)$")
  if not prefix then
    return false
  end
  prefix, suffix = vim.trim(prefix), vim.trim(suffix)

  local body = vim.trim(line)
  if prefix ~= "" then
    if body:sub(1, #prefix) ~= prefix then
      return false
    end
    body = vim.trim(body:sub(#prefix + 1))
  end
  if suffix ~= "" then
    if body:sub(-#suffix) ~= suffix then
      return false
    end
    body = vim.trim(body:sub(1, #body - #suffix))
  end

  return body:sub(1, #marker + 1) == marker .. ":"
end

--- Delete every marker comment in a buffer.
---
--- Like `insert()`, this leaves the buffer modified and unsaved: the plugin does
--- the mechanical part, `:w` is yours.
---@param buf integer
---@return integer removed, string|nil error
function M.clear(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return 0, "no such buffer"
  end

  local marker = require("mentor.config").get().learning.marker
  local cs = M.commentstring(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  local hits = {}
  for i, line in ipairs(lines) do
    if M.is_marker(line, cs, marker) then
      table.insert(hits, i)
    end
  end
  if #hits == 0 then
    -- Nothing to say about a read-only buffer that holds no markers.
    return 0, nil
  end

  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    local name = vim.api.nvim_buf_get_name(buf)
    return 0, (name ~= "" and vim.fn.fnamemodify(name, ":.") or "buffer") .. " is not modifiable"
  end

  -- Bottom-up, so a deletion does not shift the lines still to be removed.
  for i = #hits, 1, -1 do
    vim.api.nvim_buf_set_lines(buf, hits[i] - 1, hits[i], false, {})
  end
  return #hits, nil
end

--- Every file in the repo that might hold a marker.
---
--- Loaded buffers cover the ones this session inserted into (`insert()` loads
--- its target and leaves it unsaved). `git grep` finds the ones written in an
--- earlier session, including untracked files, and is skipped outside a repo.
--- Buffers from *other* projects stay out of it: a repo-wide sweep is this
--- repo's, not everything nvim happens to have open.
---@param marker string
---@return integer[] bufs
local function sweep_targets(marker)
  local root = context.git_root()

  local seen, bufs = {}, {}
  local function add(buf)
    if buf and not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
      seen[buf] = true
      table.insert(bufs, buf)
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == ""
      and name ~= ""
      and (not root or vim.startswith(name, root .. "/"))
    then
      add(buf)
    end
  end

  if not root then
    return bufs
  end

  local ok, res = pcall(function()
    return vim
      .system({ "git", "-C", root, "grep", "--untracked", "-l", "-F", "-e", marker .. ":" }, { text = true })
      :wait(5000)
  end)
  -- git grep exits 1 when nothing matched, which is not an error.
  if not ok or (res.code ~= 0 and res.code ~= 1) then
    return bufs
  end

  for _, rel in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
    local path = root .. "/" .. rel
    if vim.fn.filereadable(path) == 1 then
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)
      add(buf)
    end
  end
  return bufs
end

--- Clear markers across the whole repo.
---@return integer removed, integer buffers, string[] errors
function M.clear_all()
  local marker = require("mentor.config").get().learning.marker
  local removed, touched, errors = 0, 0, {}
  for _, buf in ipairs(sweep_targets(marker)) do
    local n, err = M.clear(buf)
    if n > 0 then
      removed = removed + n
      touched = touched + 1
    elseif err then
      table.insert(errors, err)
    end
  end
  return removed, touched, errors
end

---@param items table[]
---@return integer inserted, string[] errors
function M.insert_all(items)
  -- Insert bottom-up so earlier insertions do not shift later line numbers.
  local sorted = vim.deepcopy(items)
  table.sort(sorted, function(a, b)
    if a.path == b.path then
      return (a.line or 0) > (b.line or 0)
    end
    return a.path < b.path
  end)

  local inserted, errors = 0, {}
  for _, item in ipairs(sorted) do
    local ok, msg = M.insert(item)
    if ok then
      inserted = inserted + 1
    else
      table.insert(errors, msg)
    end
  end
  return inserted, errors
end

return M
