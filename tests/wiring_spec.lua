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
  "MentorReset", "MentorTodos", "MentorTodoInsert", "MentorTodoClear",
  "MentorInit", "MentorRevision", "MentorModel",
}) do
  h.check("command :" .. name, cmds[name] ~= nil)
end
h.check(":MentorAsk accepts a range", cmds.MentorAsk and cmds.MentorAsk.range ~= nil)
h.check(":MentorTodoClear takes a bang", cmds.MentorTodoClear and cmds.MentorTodoClear.bang == true)

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

-- And the argv it becomes, since that is what the CLI actually enforces.
local cli = require("mentor.provider.claude_cli")
local function denied_in(args)
  for i, a in ipairs(args) do
    if a == "--disallowedTools" then
      return vim.split(args[i + 1], ",", { plain = true })
    end
  end
  return {}
end
local denied = denied_in(cli.build_args(cfg.claude_cli, "sys", {}))
for _, rule in ipairs({ "Edit", "Write", "Bash", "Read(~/.ssh/**)", "Read(~/.claude/**)", "Read(//**/.env)" }) do
  h.check("argv denies " .. rule, vim.tbl_contains(denied, rule), table.concat(denied, ","))
end
local open = denied_in(cli.build_args(vim.tbl_extend("force", cfg.claude_cli, { deny_read = false }), "sys", {}))
h.check("deny_read=false drops only the path rules",
  vim.tbl_contains(open, "Write") and not vim.tbl_contains(open, "Read(~/.ssh/**)"), table.concat(open, ","))

-- The API key must never be in curl's argv, where `ps` shows it to anyone.
local http = require("mentor.provider.openai_compat")
local real_system, real_available = vim.system, http.available
local spawned, on_exit, header_path, header_mode, header_text
http.available = function() return true end
vim.system = function(cmd, _, cb)
  spawned, on_exit = cmd, cb
  for i, a in ipairs(cmd) do
    if a == "-H" and cmd[i + 1]:sub(1, 1) == "@" then
      header_path = cmd[i + 1]:sub(2)
    end
  end
  local st = header_path and vim.uv.fs_stat(header_path)
  header_mode = st and bit.band(st.mode, 511)
  header_text = header_path and table.concat(vim.fn.readfile(header_path), "\n")
  return { kill = function() end }
end
vim.env.MENTOR_TEST_KEY = "sk-test-canary"
http.chat({
  prompt = "hi", system = "sys", state = {}, cwd = dir,
  cfg = vim.tbl_extend("force", cfg.openai_compat,
    { api_key_env = "MENTOR_TEST_KEY", extra_headers = { ["X-Evil"] = "a\r\nX-Injected: 1" } }),
  on_delta = function() end, on_error = function() end, on_done = function() end,
})
vim.system, http.available = real_system, real_available

h.check("curl was spawned", spawned ~= nil)
h.check("key is not in argv",
  spawned and not table.concat(spawned, " "):find("sk-test-canary", 1, true), spawned and table.concat(spawned, " "))
h.check("headers go by file", header_path ~= nil)
h.eq("header file is 0600", header_mode, 384)
h.check("header file carries the key", header_text and header_text:find("Bearer sk-test-canary", 1, true) ~= nil)
h.check("a header value cannot add a header",
  header_text and not header_text:find("\nX-Injected", 1, true), header_text)
if on_exit then
  on_exit({ code = 0 })
end
h.check("header file is gone after the request", header_path and not vim.uv.fs_stat(header_path))

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
