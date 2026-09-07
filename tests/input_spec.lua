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

------------------------------------------------------------- panel commands

-- A question that merely starts with a slash is still a question.
captured = nil
vim.api.nvim_buf_set_lines(ui.state.input_buf, 0, -1, false, { "/usr/bin/env, what is that?" })
ui.submit()
h.eq("a path is not a command", captured, "/usr/bin/env, what is that?")

session.ask = real_ask

local resumed = "none"
local real_resume = session.resume
session.resume = function(which) resumed = which end

local function type_in(text)
  vim.api.nvim_buf_set_lines(ui.state.input_buf, 0, -1, false, { text })
  ui.submit()
end
local function input_text()
  return table.concat(vim.api.nvim_buf_get_lines(ui.state.input_buf, 0, -1, false), "")
end

type_in("/resume")
h.eq("/resume takes the most recent", resumed, "1")
h.eq("...and clears the box", input_text(), "")

type_in("/resume 3")
h.eq("/resume n takes that one", resumed, "3")

type_in("/resume list")
h.eq("/resume list opens the picker", resumed, nil)

-- A typo must not cost a turn, and must not lose what you typed.
resumed = "none"
captured = nil
local warned = 0
local real_notify = vim.notify
vim.notify = function(_, level)
  if level == vim.log.levels.WARN then
    warned = warned + 1
  end
end
session.ask = function(text) captured = text end
type_in("/resune")
session.ask = real_ask
vim.notify = real_notify

h.check("an unknown command is not sent to the model", captured == nil)
h.eq("...it is reported", warned, 1)
h.eq("...and the text stays put", input_text(), "/resune")

local revised = false
local real_revise = session.revise
session.revise = function() revised = true end
type_in("/revise")
session.revise = real_revise
h.check("/revise drafts a brief revision", revised)

type_in("/help")
local help = table.concat(ui.lines(), "\n")
h.check("/help lists the commands", help:find("/resume list", 1, true) ~= nil, help)
h.check("...every one of them", help:find("/stop", 1, true) ~= nil, help)
h.check("...with what they do", help:find("cancel the answer in flight", 1, true) ~= nil, help)

session.resume = real_resume

---------------------------------------------------------- command completion

-- The popup itself is insert mode and not assertable headlessly; what is
-- checkable is the function behind it, which is where the decisions live. The
-- interaction was verified against a real nvim over --listen + --remote-send:
-- `/` leaves the line at `/` and lists all four, typing narrows the highlight
-- without touching the text, <C-n> inserts, and completeopt comes back after.
h.eq("the input box has a completefunc",
  vim.bo[ui.state.input_buf].completefunc, "v:lua.require'mentor.ui'.complete_command")
h.check("/ opens it from insert mode", has_map(ui.state.input_buf, "i", "/"))
-- The borrow is only safe because something always hands completeopt back.
h.eq("completeopt is restored when the menu closes", #vim.api.nvim_get_autocmds({
  group = "mentor_complete", buffer = ui.state.input_buf }), 2)

ui.focus_input()
vim.cmd("stopinsert")

local function findstart(line)
  vim.api.nvim_buf_set_lines(ui.state.input_buf, 0, -1, false, { line })
  return ui.complete_command(1, "")
end

h.eq("a bare slash completes", findstart("/"), 0)
h.eq("a half-typed name completes", findstart("/re"), 0)
-- The same guard submit applies: past the first word it is prose.
h.eq("a path does not", findstart("/usr/bin/env, what is that?"), -1)
h.eq("a slash mid-sentence does not", findstart("how do I /reset"), -1)
h.eq("a finished command does not", findstart("/resume list"), -1)

local function words(base)
  local out = {}
  for _, item in ipairs(ui.complete_command(0, base)) do
    out[#out + 1] = item.word
  end
  return out
end

local all = words("/")
h.check("every command is offered", vim.tbl_contains(all, "/help")
  and vim.tbl_contains(all, "/reset") and vim.tbl_contains(all, "/resume")
  and vim.tbl_contains(all, "/stop"), table.concat(all, " "))
h.check("in a stable order", vim.deep_equal(all, words("/")), table.concat(all, " "))
h.eq("prefixes narrow it", table.concat(words("/res"), " "), "/reset /resume")
h.eq("...on the shared prefix too", table.concat(words("/re"), " "),
  "/reset /resume /revise")
h.eq("...to nothing when nothing matches", #words("/zz"), 0)
h.eq("argument forms stay out of the menu", #words("/resume "), 0)

local first = ui.complete_command(0, "/st")[1]
h.eq("each carries its description", first and first.menu, "cancel the answer in flight")

vim.api.nvim_buf_set_lines(ui.state.input_buf, 0, -1, false, { "" })

ui.close()
h.check("close tears down both windows", not ui.win_valid() and not ui.input_win_valid())

-- Someone with their own completion on `/` needs the key back.
vim.api.nvim_buf_delete(ui.state.input_buf, { force = true })
cfg.window.complete_commands = false
local plain = ui.ensure_input_buf()
h.eq("complete_commands=false leaves completefunc alone", vim.bo[plain].completefunc, "")
h.check("...and / stays a plain keystroke", not has_map(plain, "i", "/"))
cfg.window.complete_commands = true
vim.api.nvim_buf_delete(plain, { force = true })

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
