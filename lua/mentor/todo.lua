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
