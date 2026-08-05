--- Saved conversations: what a turn writes, what :MentorResume hands back, and
--- what stays out of the store.
local h = require("harness")

local dir = h.fixture()
h.enter(dir)

local state = vim.fn.tempname()
require("mentor").setup({ history = { dir = state, max = 3 } })

local session = require("mentor.session")
local store = require("mentor.store")
local context = require("mentor.context")
local provider = require("mentor.provider")
local ui = require("mentor.ui")
local cfg = require("mentor.config").get()

local real_resolve = provider.resolve

local root = context.git_root()

local function settle()
  vim.wait(2000, function()
    return not session.state.busy
  end)
end

local function ask(question)
  h.stub_provider()
  session.ask(question)
  settle()
end

------------------------------------------------------------------ one turn

h.eq("saving is on by default", require("mentor.config").defaults.history.save, true)
h.check("nothing saved yet", #session.saved() == 0)

ask("why is this wrong?")

local saved = session.saved()
h.eq("the turn was saved", #saved, 1)
h.eq("titled after the opening question", saved[1].title, "why is this wrong?")
h.eq("with a turn count", saved[1].turns, 1)
h.eq("...and the repo it belongs to", saved[1].root, root)
h.check("the transcript went with it",
  table.concat(saved[1].lines, "\n"):find("why is this wrong?", 1, true) ~= nil)

-- The whole point of saving the handle: the backend can pick the thread up.
session.state.provider_state.session_id = "sess-123"
ask("and now?")
saved = session.saved()
h.eq("a second turn updates the same conversation", #saved, 1)
h.eq("...counting up", saved[1].turns, 2)
h.eq("the title is not rewritten", saved[1].title, "why is this wrong?")
h.eq("the backend handle is stored", saved[1].provider_state.session_id, "sess-123")

h.eq("it is stored under the repo", vim.fn.isdirectory(store.dir(cfg.history, root)), 1)
local mode = vim.fn.getfperm(saved[1].path)
h.eq("readable only by you", mode, "rw-------")

-------------------------------------------------------- reset starts another

session.reset()
h.check("reset clears the live conversation", session.state.conversation == nil)
ask("a different question")
saved = session.saved()
h.eq("reset kept the old one and started a new one", #saved, 2)
h.eq("newest first", saved[1].title, "a different question")

------------------------------------------------------------------- resuming

local previous = saved[2]
session.state.provider_state = {}
session.state.briefed_root = nil
ui.clear()

session.resume("2")
h.eq("resume restores the backend handle",
  session.state.provider_state.session_id, "sess-123")
h.eq("...and the conversation it writes to", session.state.conversation.id, previous.id)

local transcript = table.concat(ui.lines(), "\n")
h.check("the panel shows the old conversation",
  transcript:find("why is this wrong?", 1, true) ~= nil, transcript)
h.check("...and says it was resumed", transcript:find("resumed —", 1, true) ~= nil)

-- Landing at line 1 of a thread you have already read means scrolling all the
-- way down before you can carry on.
h.eq("the transcript is at its end",
  vim.api.nvim_win_get_cursor(ui.state.win)[1], #ui.lines())

-- Resuming then asking must extend that conversation, not fork a third one.
ask("carrying on")
h.eq("the resumed conversation is the one that grows", #session.saved(), 2)
h.eq("...by one turn", session.saved()[1].turns, 3)

h.check("a position that does not exist is refused", pcall(session.resume, "99"))

-- No argument picks, through whatever vim.ui.select the user has wired up.
-- Closing the panel first: resuming in a fresh nvim starts from nothing open.
ui.close()
local offered = {}
local real_select = vim.ui.select
vim.ui.select = function(items, opts, cb)
  for _, item in ipairs(items) do
    offered[#offered + 1] = opts.format_item(item)
  end
  cb(items[2]) -- the older one
end
session.resume()
vim.ui.select = real_select

h.eq("the picker offers every conversation", #offered, 2)
h.check("...described by age, title and length",
  offered[1]:find("just now", 1, true) ~= nil
  and offered[1]:find("turn", 1, true) ~= nil, offered[1])
h.check("resuming opens the panel", ui.win_valid())
h.check("...and lands in the input box",
  vim.api.nvim_get_current_win() == ui.state.input_win)
-- The panel was closed when this started: filling a windowless buffer used to
-- leave the view pinned to line 1.
h.eq("...with the transcript at its end from closed",
  vim.api.nvim_win_get_cursor(ui.state.win)[1], #ui.lines())
-- Position 2 is the other conversation: "carrying on" just moved this one to
-- the top of the list.
h.check("the chosen one is loaded",
  table.concat(ui.lines(), "\n"):find("a different question", 1, true) ~= nil)
h.eq("...and it is the one further turns extend",
  session.state.conversation.title, "a different question")

------------------------------------------------------------------- pruning

for i = 1, 3 do
  session.reset()
  ask("question " .. i)
end
h.eq("max caps what is kept", #session.saved(), 3)
h.check("the oldest went first",
  session.saved()[#session.saved()].title ~= "why is this wrong?")

------------------------------------------------------------- what is not saved

-- :MentorInit is a side request with its own state; it is not a conversation.
local before = #session.saved()
vim.fn.delete(root .. "/MENTOR.md")
h.stub_provider()
session.init()
settle()
h.eq("drafting a brief saves no conversation", #session.saved(), before)

-- save = false is memory only.
require("mentor").setup({ history = { dir = state .. "-off", save = false } })
session.reset()
ask("not for the record")
h.eq("save=false writes nothing", #session.saved(), 0)

------------------------------------------- a session the backend no longer has

-- Resuming hands the CLI a session id it may have pruned since. A fake `claude`
-- answering the way the real one does, so this stays offline: the id has to be
-- dropped, or every question from here on fails the same way.
local fake = dir .. "/fake-claude"
vim.fn.writefile({
  "#!/bin/sh",
  "cat > /dev/null",
  'echo \'{"type":"result","is_error":true,"session_id":"dead-id",'
    .. '"errors":["No conversation found with session ID: dead-id"]}\'',
  "exit 1",
}, fake)
vim.fn.setfperm(fake, "rwx------")

provider.resolve = real_resolve
require("mentor").setup({
  provider = "claude_cli",
  history = { dir = state },
  claude_cli = { cmd = fake },
})
session.reset()
session.state.provider_state = { session_id = "dead-id" }

local errors = 0
local real_notify = vim.notify
vim.notify = function() errors = errors + 1 end
session.ask("does this still work?")
settle()
vim.notify = real_notify

h.eq("the dead session id is dropped", session.state.provider_state.session_id, nil)
h.eq("and it is reported once, not twice", errors, 1)
h.check("the panel says what happened",
  table.concat(ui.lines(), "\n"):find("No conversation found", 1, true) ~= nil)

h.cleanup(state)
h.cleanup(dir)
