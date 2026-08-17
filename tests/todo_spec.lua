--- Parsing TODO(human) items out of the transcript, and the on/off toggle.
local h = require("harness")

local dir = h.fixture()
h.enter(dir)
require("mentor").setup({})

local todo = require("mentor.todo")

for _, case in ipairs({
  { "- `cart.py:5` — decide the thing", "cart.py", 5, "decide the thing" },
  { "- cart.py:12 - plain dash form", "cart.py", 12, "plain dash form" },
  { "* `a/b/c.lua:3`: colon form", "a/b/c.lua", 3, "colon form" },
}) do
  local item = todo.parse_line(case[1])
  h.check("parse " .. case[1],
    item and item.path == case[2] and item.line == case[3] and item.text == case[4],
    item and (item.path .. ":" .. item.line .. " " .. item.text) or "nil")
end

h.check("ignores prose", todo.parse_line("- Line 4: you now require every item") == nil)
h.check("ignores an empty description", todo.parse_line("- `cart.py:5` —") == nil)
-- A literal % must survive: it is a gsub replacement char when building comments.
local pct = todo.parse_line("- `x.py:1` — apply 50% off")
h.check("percent in text is preserved", pct and pct.text == "apply 50% off", pct and pct.text)

-- Only the most recent block, so re-inserting does not replay the whole session.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "## TODO(human)",
  "- `cart.py:1` — old one",
  "",
  "some prose in between",
  "",
  "## TODO(human)",
  "- `cart.py:4` — new one",
  "- `cart.py:5` — also new",
})
local block = todo.parse_last_block(buf)
h.eq("last block size", #block, 2)
h.eq("last block starts at the newest section", block[1].text, "new one")
h.eq("whole buffer still parses everything", #todo.parse_buffer(buf), 3)

local cfg = require("mentor.config").get()
h.eq("todos on by default", cfg.learning.todos, true)
h.eq("marker default", cfg.learning.marker, "TODO(human)")
h.eq("todo keymap", cfg.keymaps.todos, "<leader>mt")
h.eq("insert keymap", cfg.keymaps.todo_insert, "<leader>mi")
h.eq("clear keymap", cfg.keymaps.todo_clear, "<leader>mc")

---------------------------------------------------------------- clearing them

-- What insert() writes must be what clear() recognises, in every syntax.
for _, case in ipairs({
  { cs = "# %s", line = "    # TODO(human): do the thing" },
  { cs = "-- %s", line = "-- TODO(human): do the thing" },
  { cs = "// %s", line = "\t// TODO(human): do the thing" },
  { cs = "/* %s */", line = "/* TODO(human): do the thing */" },
  { cs = "<!-- %s -->", line = "<!-- TODO(human): do the thing -->" },
}) do
  h.check("recognises " .. case.cs, todo.is_marker(case.line, case.cs, "TODO(human)"), case.line)
end

for _, case in ipairs({
  { cs = "# %s", line = "x = 1  # TODO(human): trailing, not ours", why = "marker after code" },
  { cs = "# %s", line = "# TODO(human) without the colon", why = "no colon" },
  { cs = "# %s", line = "# see TODO(human): items in the README", why = "marker not first" },
  { cs = "# %s", line = "result = total(items)", why = "plain code" },
  { cs = "-- %s", line = "# TODO(human): wrong comment syntax", why = "prefix mismatch" },
}) do
  h.check("leaves alone: " .. case.why, not todo.is_marker(case.line, case.cs, "TODO(human)"), case.line)
end

-- Round trip: insert into a real file, clear it, get the original back.
local before = vim.fn.readfile(dir .. "/mod.lua")
todo.insert({ path = "mod.lua", line = 1, text = "name the module" })
todo.insert({ path = "mod.lua", line = 2, text = "and export it" })

local mod = vim.fn.bufadd(dir .. "/mod.lua")
vim.fn.bufload(mod)
h.eq("two markers in the buffer", vim.api.nvim_buf_line_count(mod), #before + 2)

local removed, err = todo.clear(mod)
h.eq("both removed", removed, 2)
h.check("no error", err == nil, err)
h.eq("file is back to what it was",
  table.concat(vim.api.nvim_buf_get_lines(mod, 0, -1, false), "\n"),
  table.concat(before, "\n"))

h.eq("clearing again is a no-op", (todo.clear(mod)), 0)

-- The sweep finds a marker in a file this session never opened.
vim.fn.writefile({ "-- TODO(human): left over from last time", "return 1" }, dir .. "/stale.lua")
local swept, buffers = todo.clear_all()
h.check("sweep removed the stale marker", swept >= 1, swept)
h.check("sweep touched a buffer", buffers >= 1, buffers)
local stale = vim.fn.bufadd(dir .. "/stale.lua")
vim.fn.bufload(stale)
h.eq("stale marker is gone", vim.api.nvim_buf_get_lines(stale, 0, -1, false)[1], "return 1")
h.check("sweep left the buffer unsaved", vim.bo[stale].modified)
h.eq("the file on disk is untouched until you save", #vim.fn.readfile(dir .. "/stale.lua"), 2)

local prompts = require("mentor.prompts")
h.check("todo instructions exist", prompts.todo_instructions:find("TODO(human)", 1, true) ~= nil)

h.eq("toggle flips off", require("mentor").toggle_todos(), false)
h.eq("toggle flips back on", require("mentor").toggle_todos(), true)
h.eq("explicit off", require("mentor").toggle_todos(false), false)

h.cleanup(dir)
