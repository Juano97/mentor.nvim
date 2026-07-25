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

local prompts = require("mentor.prompts")
h.check("todo instructions exist", prompts.todo_instructions:find("TODO(human)", 1, true) ~= nil)

h.eq("toggle flips off", require("mentor").toggle_todos(), false)
h.eq("toggle flips back on", require("mentor").toggle_todos(), true)
h.eq("explicit off", require("mentor").toggle_todos(false), false)

h.cleanup(dir)
