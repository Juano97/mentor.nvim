--- TODO markers must use the right comment syntax for the target file.
---
--- Regression: todo.insert() opens files with bufadd()+bufload(), which never
--- runs filetype detection, so 'commentstring' is empty. A naive "# %s"
--- fallback wrote Python comments into Lua, JS and CSS files.
local h = require("harness")

local dir = h.fixture()
h.enter(dir) -- only cart.py is opened; the rest stay unopened on purpose
require("mentor").setup({})

local todo = require("mentor.todo")

for _, case in ipairs({
  { file = "cart.py", prefix = "# " },
  { file = "mod.lua", prefix = "-- " },
  { file = "app.js", prefix = "// " },
  { file = "style.css", prefix = "/* " },
}) do
  local ok, msg = todo.insert({ path = case.file, line = 1, text = "decide the thing" })
  h.check("insert into " .. case.file, ok, msg)

  local buf = vim.fn.bufadd(dir .. "/" .. case.file)
  vim.fn.bufload(buf)
  local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  h.check(case.file .. " uses " .. vim.trim(case.prefix),
    first:sub(1, #case.prefix) == case.prefix, first)
  h.check(case.file .. " keeps the description", first:find("decide the thing", 1, true) ~= nil)
end

-- Indentation of the target line is preserved.
local buf = vim.fn.bufadd(dir .. "/cart.py")
vim.fn.bufload(buf)
local indented = nil
for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if line:find("result += item.price", 1, true) then
    indented = i
    break
  end
end
h.check("found an indented line to target", indented ~= nil)
if indented then
  todo.insert({ path = "cart.py", line = indented, text = "check the qty assumption" })
  local inserted = vim.api.nvim_buf_get_lines(buf, indented - 1, indented, false)[1]
  h.check("marker matches the target's indentation",
    inserted:match("^        # TODO") ~= nil, vim.inspect(inserted))
end

-- Out-of-range and missing files report instead of raising.
local ok_missing, msg_missing = todo.insert({ path = "nope.txt", line = 1, text = "x" })
h.check("missing file reports an error", ok_missing == false and type(msg_missing) == "string", msg_missing)

local ok_far = todo.insert({ path = "cart.py", line = 9999, text = "clamped" })
h.check("line beyond EOF is clamped, not an error", ok_far == true)

-- Bottom-up ordering: inserting several markers must not shift each other.
vim.fn.writefile({ "one", "two", "three", "four" }, dir .. "/order.txt")
local n, errs = todo.insert_all({
  { path = "order.txt", line = 1, text = "first" },
  { path = "order.txt", line = 3, text = "third" },
})
h.eq("both inserted", n, 2)
h.eq("no errors", #errs, 0)
local ob = vim.fn.bufadd(dir .. "/order.txt")
vim.fn.bufload(ob)
local lines = vim.api.nvim_buf_get_lines(ob, 0, -1, false)
h.check("first marker above line 1", lines[1]:find("first", 1, true) ~= nil, lines[1])
h.check("third marker still above 'three'",
  lines[4]:find("third", 1, true) ~= nil and lines[5] == "three",
  table.concat(lines, " | "))

h.cleanup(dir)
