--- Plugin loads, commands register, config merges, transcript streams.
local h = require("harness")

local dir = h.fixture()
h.enter(dir)

local ok, mentor = pcall(require, "mentor")
h.check("require('mentor')", ok, not ok and mentor or nil)
if not ok then
  h.cleanup(dir)
  return
end

h.check("setup()", pcall(mentor.setup, { window = { width = 0.2 }, keymaps = { ask = false } }))

local cmds = vim.api.nvim_get_commands({})
for _, name in ipairs({
  "Mentor", "MentorAsk", "MentorReview", "MentorStop",
  "MentorReset", "MentorTodos", "MentorTodoInsert",
}) do
  h.check("command :" .. name, cmds[name] ~= nil)
end
h.check(":MentorAsk accepts a range", cmds.MentorAsk and cmds.MentorAsk.range ~= nil)

local cfg = require("mentor.config").get()
h.eq("override applied", cfg.window.width, 0.2)
h.eq("untouched default kept", cfg.window.position, "right")
h.eq("keymap disable honoured", cfg.keymaps.ask, false)

-- The read-only guarantee is config, so assert it rather than trusting it.
h.eq("allowlist", table.concat(cfg.claude_cli.tools, ","), "Read,Grep,Glob")
for _, tool in ipairs({ "Edit", "Write", "Bash" }) do
  h.check("denied: " .. tool, vim.tbl_contains(cfg.claude_cli.disallowed_tools, tool))
end
h.eq("mcp servers excluded", cfg.claude_cli.strict_mcp_config, true)
h.eq("ambient settings excluded", cfg.claude_cli.setting_sources, "")

local ui = require("mentor.ui")
ui.open(cfg.window)
h.check("panel opens", ui.win_valid())
h.check("panel respects min width",
  vim.api.nvim_win_get_width(ui.state.win) >= cfg.window.min_width)

ui.header("user")
ui.append("hello\n")
ui.header("mentor")
ui.append("par") -- deltas arriving mid-line
ui.append("tial ")
ui.append("stream\nsecond line\n")
local joined = table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "|")
h.check("streaming append reassembles lines",
  joined:find("partial stream|second line", 1, true) ~= nil, joined)
h.eq("transcript stays read-only", vim.bo[ui.state.buf].modifiable, false)

local impl, name = require("mentor.provider").resolve(cfg)
h.check("provider resolves", impl ~= nil, name)
h.eq("auto picks by availability", name,
  vim.fn.executable(cfg.claude_cli.cmd) == 1 and "claude_cli" or "openai_compat")

local context = require("mentor.context")
local diff, label = context.recent_changes(cfg.context)
h.check("recent_changes finds the working-tree diff",
  diff ~= nil and diff:find("qty", 1, true) ~= nil, label)

-- Outside a repo it must report, not raise.
local plain = vim.fn.tempname()
vim.fn.mkdir(plain, "p")
vim.cmd("enew")
vim.cmd("cd " .. vim.fn.fnameescape(plain))
local none, err = context.recent_changes(cfg.context)
h.check("outside a repo returns an error string", none == nil and type(err) == "string", err)

h.check("health.check() runs", pcall(require("mentor.health").check))

h.cleanup(plain)
h.cleanup(dir)
