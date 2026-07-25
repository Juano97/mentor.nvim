--- The panel's input box, and the fact that context still points at the code
--- buffer even though the cursor is in the panel when you hit send.
local h = require("harness")

local dir = h.fixture()
h.enter(dir)
require("mentor").setup({})

local ui = require("mentor.ui")
local session = require("mentor.session")
local context = require("mentor.context")
local cfg = require("mentor.config").get()

local before = #vim.api.nvim_list_wins()
ui.open(cfg.window)
h.eq("opens two windows", #vim.api.nvim_list_wins(), before + 2)
h.check("transcript window valid", ui.win_valid())
h.check("input window valid", ui.input_win_valid())
h.eq("input is writable", vim.bo[ui.state.input_buf].modifiable, true)
h.eq("transcript is not", vim.bo[ui.state.buf].modifiable, false)
h.eq("input height", vim.api.nvim_win_get_height(ui.state.input_win), cfg.window.input_height)
h.eq("both share the column width",
  vim.api.nvim_win_get_width(ui.state.win), vim.api.nvim_win_get_width(ui.state.input_win))

local function has_map(buf, mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if m.lhs == lhs then
      return true
    end
  end
  return false
end
h.check("<CR> sends from normal mode", has_map(ui.state.input_buf, "n", "<CR>"))
h.check("<C-s> sends from insert mode", has_map(ui.state.input_buf, "i", "<C-S>"))
h.check("transcript <CR> inserts a TODO", has_map(ui.state.buf, "n", "<CR>"))

ui.focus_input()
vim.cmd("stopinsert")
h.check("focus_input moves the cursor there",
  vim.api.nvim_get_current_win() == ui.state.input_win)

-- The important one: cursor is in the panel, context must not follow it.
local ctx = context.cursor_context()
h.check("context tracks the code buffer", ctx ~= nil and ctx.path == "cart.py",
  ctx and ctx.path or "nil")
h.eq("git root resolves from the panel", context.git_root(), vim.fn.resolve(dir))

local captured
local real_ask = session.ask
session.ask = function(text) captured = text end

vim.api.nvim_buf_set_lines(ui.state.input_buf, 0, -1, false, { "why is this wrong?", "second line" })
ui.submit()
h.eq("submit forwards the text", captured, "why is this wrong?\nsecond line")
h.eq("input clears after submit",
  table.concat(vim.api.nvim_buf_get_lines(ui.state.input_buf, 0, -1, false), ""), "")

captured = nil
ui.submit()
h.check("empty submit is a no-op", captured == nil)

captured = nil
vim.api.nvim_buf_set_lines(ui.state.input_buf, 0, -1, false, { "   ", "" })
ui.submit()
h.check("whitespace-only submit is a no-op", captured == nil)

session.ask = real_ask

ui.close()
h.check("close tears down both windows", not ui.win_valid() and not ui.input_win_valid())

---------------------------------------------------------------- toggle focus

-- Opening by hand should leave you ready to type, unlike the streaming path.
local code_win = vim.api.nvim_get_current_win()
ui.toggle(cfg.window)
vim.cmd("stopinsert")
h.check("toggle opens into the input box",
  vim.api.nvim_get_current_win() == ui.state.input_win)

ui.toggle(cfg.window)
h.check("toggle closes again", not ui.win_valid())

ui.toggle(vim.tbl_extend("force", cfg.window, { focus_on_open = false }))
h.check("focus_on_open=false leaves the cursor put",
  vim.api.nvim_get_current_win() == code_win)
ui.close()

-- The streaming path must never yank the cursor out of the code buffer.
ui.open(cfg.window)
h.check("open on its own does not steal focus",
  vim.api.nvim_get_current_win() == code_win)
ui.close()

h.cleanup(dir)
