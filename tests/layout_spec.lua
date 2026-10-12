--- Where drafts open: beside your code, whatever window you launched from.
---
--- The bug this pins: launched with the cursor in the panel, a draft opened in
--- the panel's column. Loading the draft fired a BufEnter in nvim's hidden
--- autocommand window, the tracker took the draft for "the last code buffer",
--- and with no window showing it the host fell back to the first window in the
--- list — a file explorer, which moved focus into its own popup on entry.
local h = require("harness")

local dir = h.fixture()
h.enter(dir)
require("mentor").setup({})

local brief = require("mentor.brief")
local context = require("mentor.context")
local session = require("mentor.session")
local ui = require("mentor.ui")
local cfg = require("mentor.config").get()

h.stub_provider()

local function settle()
  vim.wait(2000, function()
    return not session.state.busy
  end)
end

local function win_showing(path)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)) == path then
      return w
    end
  end
  return nil
end

local function col(win)
  return vim.api.nvim_win_get_position(win)[2]
end

local root = context.git_root()
local code_win = vim.api.nvim_get_current_win()
local code_buf = vim.api.nvim_get_current_buf()

-- A sidebar, first in the window list, the way a file explorer sits.
vim.cmd("topleft vsplit")
local sidebar = vim.api.nvim_get_current_win()
local scratch = vim.api.nvim_create_buf(false, true)
vim.bo[scratch].buftype = "nofile"
vim.api.nvim_win_set_buf(sidebar, scratch)
vim.api.nvim_win_set_width(sidebar, 20)
vim.api.nvim_set_current_win(code_win)
context.track()

------------------------------------------------------------------ the tracker

-- A float is not somewhere the user went: nvim's autocommand window is one,
-- and so is every picker.
local other = vim.fn.bufadd(dir .. "/mod.lua")
vim.fn.bufload(other)
local float = vim.api.nvim_open_win(other, true,
  { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
context.track()
vim.api.nvim_win_close(float, true)
h.eq("a buffer entered in a float is not the code buffer", context.last_code_buf, code_buf)

---------------------------------------------------------- from the panel

ui.open(cfg.window)
ui.focus_input(cfg.window)
h.eq("launched from the input box", vim.api.nvim_get_current_win(), ui.state.input_win)

session.init()
settle()
local draft = win_showing(root .. "/MENTOR.md")
h.check("the draft gets a window", draft ~= nil)
h.eq("...in the code's column", col(draft), col(code_win))
h.check("...not the panel's", col(draft) ~= col(ui.state.win))
h.check("the panel is still two windows",
  vim.api.nvim_win_is_valid(ui.state.win) and vim.api.nvim_win_is_valid(ui.state.input_win))
local draft_buf = vim.api.nvim_win_get_buf(draft)
vim.api.nvim_win_close(draft, true)
vim.api.nvim_buf_delete(draft_buf, { force = true })

-- The tracker pointed at a buffer no window shows, which is what the stray
-- BufEnter left behind. The fallback is a window on a real file, not the
-- first window in the list.
local hidden = vim.fn.bufadd(dir .. "/app.js")
vim.fn.bufload(hidden)
context.last_code_buf = hidden
ui.focus_input(cfg.window)
session.init()
settle()
draft = win_showing(root .. "/MENTOR.md")
h.eq("with no window on the code buffer, a file window hosts it", col(draft), col(code_win))
h.check("...never the sidebar", col(draft) ~= col(sidebar))
draft_buf = vim.api.nvim_win_get_buf(draft)
vim.api.nvim_win_close(draft, true)
vim.api.nvim_buf_delete(draft_buf, { force = true })
context.last_code_buf = code_buf

---------------------------------------------------------------- a revision

vim.fn.writefile({ "# Cart", "", "A teaching fixture." }, root .. "/MENTOR.md")
ui.focus_input(cfg.window)
session.revise()
settle()
local rev = win_showing(root .. "/MENTOR.md.new")
local half = rev and brief.diff_of(vim.api.nvim_win_get_buf(rev))
h.check("the revision gets a window", rev ~= nil)
-- Which half is on the left is 'splitright''s business, not ours.
h.eq("...in the code's column", math.min(col(rev), col(half.win)), col(code_win))
h.eq("...with the brief beside it, on the same row",
  vim.api.nvim_win_get_position(half.win)[1], vim.api.nvim_win_get_position(rev)[1])
h.check("...still left of the panel", half ~= nil and col(half.win) < col(ui.state.win))
h.check("the two halves are the same width, give or take a column",
  half ~= nil and math.abs(vim.api.nvim_win_get_width(rev) - vim.api.nvim_win_get_width(half.win)) <= 1,
  half and ("%d vs %d"):format(vim.api.nvim_win_get_width(rev), vim.api.nvim_win_get_width(half.win)))

h.cleanup(dir)
