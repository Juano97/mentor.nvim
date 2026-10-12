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

--------------------------------------------------------------- scroll clamp

-- The clamp itself needs a real UI to assert: WinScrolled fires from the main
-- loop after a redraw, and headless never redraws. What is checkable here is
-- that the hook is on the transcript and only the transcript.
local function scroll_autocmds(win)
  return vim.api.nvim_get_autocmds({
    group = "mentor_panel",
    event = "WinScrolled",
    pattern = tostring(win),
  })
end

h.eq("clamping is on by default", cfg.window.scroll_past_end, false)
h.eq("the transcript is hooked", #scroll_autocmds(ui.state.win), 1)
-- The input box has to follow the cursor as you type, so it is left alone.
h.eq("the input box is not", #scroll_autocmds(ui.state.input_win), 0)

ui.close()
h.check("closing drops the hook", not pcall(vim.api.nvim_get_autocmds,
  { group = "mentor_panel", event = "WinScrolled" }))

ui.open(vim.tbl_extend("force", cfg.window, { scroll_past_end = true }))
h.eq("scroll_past_end opts out", #scroll_autocmds(ui.state.win), 0)
ui.close()
ui.open(cfg.window)

---------------------------------------------------------- input box height

-- A window opened or closed across the whole width resizes the bottom window of
-- every column, and in the panel's that is the input box. The event that fixes
-- it fires from the main loop, so drive the layout change here and run the
-- check the way the autocmd does.
local function resize_autocmds()
  return vim.api.nvim_get_autocmds({ group = "mentor_panel", event = "WinResized" })
end
h.eq("resizes are watched", #resize_autocmds(), 1)

local want = cfg.window.input_height
local function box()
  return vim.api.nvim_win_get_height(ui.state.input_win)
end
h.eq("the box starts at input_height", box(), want)
local chat_before = vim.api.nvim_win_get_height(ui.state.win)

local prev = vim.api.nvim_get_current_win()
local function terminal_open()
  vim.cmd("botright split")
  local bottom = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(bottom, math.floor(vim.o.lines / 2))
  ui.sync_input_height(want)
  return bottom
end
local function terminal_close(bottom)
  vim.api.nvim_win_close(bottom, true)
  vim.api.nvim_set_current_win(prev)
  local grew = box()
  ui.sync_input_height(want)
  return grew
end

local bottom = terminal_open()
h.eq("a full-width split does not squeeze the box", box(), want)
local grew = terminal_close(bottom)
h.eq("closing it does not leave the box tall", box(), want,
  ("it was %d before the fix"):format(grew))
h.eq("...the transcript gets the room back", vim.api.nvim_win_get_height(ui.state.win), chat_before)

-- Same windows, different height: that is a hand on the border, not a side
-- effect, and putting it back would be the plugin fighting you.
vim.api.nvim_win_set_height(ui.state.input_win, want + 4)
ui.sync_input_height(want)
h.eq("a resize by hand is kept", box(), want + 4)
h.eq("...and remembered", ui.state.input_height, want + 4)

bottom = terminal_open()
h.eq("a full-width split then keeps that height", box(), want + 4)
terminal_close(bottom)
h.eq("...and so does closing it", box(), want + 4)

-- nvim itself resizing is never a hand on the border.
vim.api.nvim_win_set_height(ui.state.input_win, 2)
ui.sync_input_height(want, true)
h.eq("a resize of nvim puts the remembered height back", box(), want + 4)

ui.close()
ui.open(cfg.window)
h.eq("reopening the panel uses the remembered height", box(), want + 4)

ui.state.input_height = nil
ui.close()
ui.open(cfg.window)
h.eq("with nothing remembered it is input_height again", box(), want)

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
