--- Busy indicator (winbar + spinner) and attaching a code selection.
local h = require("harness")

local dir = h.fixture()
h.enter(dir)
require("mentor").setup({})

local ui = require("mentor.ui")
local session = require("mentor.session")
local context = require("mentor.context")
local cfg = require("mentor.config").get()

ui.open(cfg.window)

------------------------------------------------------------- busy indicator

local function winbar()
  return vim.wo[ui.state.input_win].winbar
end

h.check("idle winbar prompts to send", winbar():find("<CR> send", 1, true) ~= nil, winbar())

ui.set_status("busy")
h.check("busy winbar says thinking", winbar():find("thinking", 1, true) ~= nil, winbar())
h.check("busy winbar mentions how to stop", winbar():find("MentorStop", 1, true) ~= nil)
h.check("spinner timer started", ui.state.timer ~= nil)

local frame = ui.state.frame
vim.wait(350)
h.check("spinner animates", ui.state.frame ~= frame,
  ("%d -> %d"):format(frame, ui.state.frame))

ui.set_status("idle")
h.check("winbar returns to idle", winbar():find("<CR> send", 1, true) ~= nil, winbar())
h.check("spinner timer stopped", ui.state.timer == nil)

ui.set_status("busy")
ui.close()
h.check("close stops the spinner", ui.state.timer == nil)
ui.open(cfg.window)
ui.set_status("idle")

------------------------------------------------------------------ selection

local visual = vim.tbl_filter(function(m)
  return m.lhs == " ma"
end, vim.api.nvim_get_keymap("x"))
h.check("visual keymap registered", #visual == 1,
  #visual .. " matches (leader is a space in tests)")

local get = h.stub_provider()

session.ask_range(1, 3)
h.eq("pending label set", ui.state.pending, "cart.py:1-3")
h.check("winbar shows what is attached", winbar():find("cart.py:1-3", 1, true) ~= nil, winbar())

session.ask("what does this do?")
vim.wait(2000, function() return get() ~= nil and not session.state.busy end, 20)

local sent = get()
h.check("prompt fences the selection with a language",
  sent and sent.prompt:find("```python", 1, true) ~= nil, sent and sent.prompt:sub(1, 120))
h.check("prompt carries the code",
  sent and sent.prompt:find("def total(items, discount=0):", 1, true) ~= nil)
h.check("prompt states the range", sent and sent.prompt:find("lines 1%-3") ~= nil)
h.check("system prompt forbids writing code",
  sent and sent.system:find("Never output a complete", 1, true) ~= nil)
h.check("pending cleared after send", ui.state.pending == nil)

local transcript = table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
h.check("transcript echoes the attachment",
  transcript:find("(about cart.py:1-3)", 1, true) ~= nil, transcript)

-- A follow-up must not silently resend the previous selection.
session.ask("and now?")
vim.wait(2000, function() return not session.state.busy end, 20)
h.check("selection is not re-sent", get().prompt:find("```", 1, true) == nil,
  get().prompt:sub(1, 120))

local code_buf = context.code_buf()
local clamped = context.selection(1, 9999, cfg.context)
h.eq("range clamps to the buffer", clamped.last, vim.api.nvim_buf_line_count(code_buf))
h.check("selection reports its filetype", clamped.filetype == "python", clamped.filetype)

local capped = context.selection(1, 9999, { max_selection_lines = 2 })
h.eq("selection respects max_selection_lines", capped.last, 2)
h.eq("truncation is flagged", capped.truncated, true)

h.cleanup(dir)
