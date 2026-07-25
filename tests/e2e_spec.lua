--- Live round-trip through the real backend. Skipped unless MENTOR_E2E=1,
--- because it spends real quota. Run with `make test-e2e`.
local h = require("harness")

if vim.env.MENTOR_E2E ~= "1" then
  h.skip("set MENTOR_E2E=1 (or run `make test-e2e`) to exercise the live backend")
  return
end

local cmd = require("mentor.config").defaults.claude_cli.cmd
if vim.fn.executable(cmd) ~= 1 then
  h.skip("`" .. cmd .. "` not on $PATH")
  return
end

local dir = h.fixture()
h.enter(dir)

require("mentor").setup({
  claude_cli = { model = "sonnet" },
  learning = { todos = true },
})

local ui = require("mentor.ui")
local session = require("mentor.session")
local todo = require("mentor.todo")

session.review()
h.check("session goes busy", session.state.busy)
local finished = vim.wait(240000, function() return not session.state.busy end, 200)
h.check("review completes", finished)

local transcript = table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
h.out("\n---- transcript ----\n" .. transcript .. "\n--------------------")

h.check("transcript has a reply", #transcript > 100, #transcript)
h.check("winbar back to idle after the reply",
  vim.wo[ui.state.input_win].winbar:find("<CR> send", 1, true) ~= nil)

-- The guardrail that actually matters: no tool ever wrote to disk.
local dirty = vim.system({ "git", "-C", dir, "status", "--porcelain" }, { text = true }):wait()
local touched = {}
for line in (dirty.stdout or ""):gmatch("[^\n]+") do
  table.insert(touched, line)
end
h.check("the model changed nothing on disk",
  #touched == 1 and touched[1]:find("cart.py", 1, true) ~= nil,
  table.concat(touched, " | "))

local items = todo.parse_last_block(ui.state.buf)
h.check("model produced TODO(human) items", #items > 0, #items)
for _, item in ipairs(items) do
  h.out(("    %s:%d  %s"):format(item.path, item.line, item.text))
end

if #items > 0 then
  local n, errs = todo.insert_all(items)
  h.check("markers insert cleanly", n == #items and #errs == 0,
    ("%d/%d, %d errors"):format(n, #items, #errs))
end

-- Multi-turn: the CLI session id must be reused for the follow-up.
local first_session = session.state.provider_state.session_id
h.check("session id captured", type(first_session) == "string", first_session)

session.ask("In one sentence, what should I read first?")
vim.wait(240000, function() return not session.state.busy end, 200)
h.check("follow-up completes", not session.state.busy)

h.cleanup(dir)
