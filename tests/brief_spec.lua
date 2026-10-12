--- The project brief: finding one, sending it once per conversation, and
--- drafting one with :MentorInit without model text reaching disk.
local h = require("harness")

local dir = h.fixture()
h.enter(dir)
require("mentor").setup({})

local brief = require("mentor.brief")
local context = require("mentor.context")
local session = require("mentor.session")
local ui = require("mentor.ui")
local ctx = require("mentor.config").get().context

local root = context.git_root()
local get = h.stub_provider()

local function settle()
  vim.wait(2000, function()
    return not session.state.busy
  end)
end

local function without(key)
  return vim.tbl_extend("force", ctx, { [key] = false })
end

---------------------------------------------------------------------- discovery

h.eq("reading is on by default", ctx.project_brief, true)
h.check("a fresh repo has no brief", brief.find(ctx) == nil)
h.check("read() is nil with no file", brief.read(ctx) == nil)

local target, name = brief.target_path(ctx)
h.eq("init targets the first candidate", name, "MENTOR.md")
h.eq("...at the repo root", target, root .. "/MENTOR.md")

vim.fn.writefile({ "# Cart", "", "The agent's file." }, dir .. "/CLAUDE.md")
local found = brief.find(ctx)
h.eq("falls back to CLAUDE.md", found and found.name, "CLAUDE.md")

vim.fn.writefile({ "# Cart", "", "The tutor's file." }, dir .. "/MENTOR.md")
h.eq("MENTOR.md wins", brief.find(ctx).name, "MENTOR.md")
h.check("read() returns the text",
  brief.read(ctx).text:find("The tutor's file.", 1, true) ~= nil)

h.check("project_brief=false stops reading", brief.read(without("project_brief")) == nil)
-- ...but the file must still be findable, or :MentorInit would clobber it.
h.check("...without hiding the file", brief.find(without("project_brief")) ~= nil)

local long = {}
for i = 1, 50 do
  long[i] = "line " .. i
end
vim.fn.writefile(long, dir .. "/MENTOR.md")
local trimmed = brief.read(vim.tbl_extend("force", ctx, { max_brief_lines = 10 }))
h.check("truncated at max_brief_lines",
  trimmed.text:find("truncated 40 more", 1, true) ~= nil, trimmed.text)

---------------------------------------------------------------------- injection

vim.fn.writefile({ "# Cart", "", "A teaching fixture." }, dir .. "/MENTOR.md")

session.ask("first question")
settle()
local req = get()
h.check("first turn carries the brief", req.prompt:find("<project_brief>", 1, true) ~= nil)
h.check("...alongside the question", req.prompt:find("first question", 1, true) ~= nil)
-- The teaching rules stay above the brief, not below it.
h.check("the brief is a user message, not the system prompt",
  req.system:find("<project_brief>", 1, true) == nil)

session.ask("second question")
settle()
h.check("a later turn does not repeat it",
  get().prompt:find("<project_brief>", 1, true) == nil)

session.reset()
session.ask("after reset")
settle()
h.check("reset sends it again", get().prompt:find("<project_brief>", 1, true) ~= nil)

------------------------------------------------------------------ a stale copy

-- Editing the brief mid-conversation used to do nothing until :MentorReset:
-- the gate was the repo root, which cannot tell "same file, new contents".
session.ask("still the same file")
settle()
h.check("an untouched brief is not re-sent",
  get().prompt:find("<project_brief>", 1, true) == nil)

vim.fn.writefile({ "# Cart", "", "A teaching fixture, revised." }, dir .. "/MENTOR.md")
session.ask("after the edit")
settle()
req = get()
h.check("an edited brief goes in again",
  req.prompt:find("<project_brief>", 1, true) ~= nil)
h.check("...carrying the new text", req.prompt:find("revised", 1, true) ~= nil)
-- The first copy is still in the history and cannot be unsent, so the second
-- has to say which one wins.
h.check("...and says it replaces the copy already sent",
  req.prompt:find("replaces that copy", 1, true) ~= nil, req.prompt)

session.ask("and on from there")
settle()
h.check("the new version settles too",
  get().prompt:find("<project_brief>", 1, true) == nil)

-- `:w` with no edit, or a formatter rewriting the file, must not spend tokens.
vim.fn.writefile({ "# Cart", "", "A teaching fixture, revised." }, dir .. "/MENTOR.md")
session.ask("rewritten byte for byte")
settle()
h.check("an identical rewrite is not re-sent",
  get().prompt:find("<project_brief>", 1, true) == nil)

-- The hash is over what is actually sent, which is the text after truncation.
-- So an edit below the cut is invisible to the model and costs nothing here —
-- the line count is part of the marker, so this holds while it stays the same.
local function padded(tail)
  local lines = { "# Cart", "", "A teaching fixture." }
  for i = 1, 40 do
    lines[#lines + 1] = tail .. " " .. i
  end
  return lines
end

require("mentor").setup({ context = { max_brief_lines = 3 } })
session.reset()
vim.fn.writefile(padded("filler"), dir .. "/MENTOR.md")
session.ask("with a truncated brief")
settle()
req = get()
h.check("the truncated brief goes in", req.prompt:find("<project_brief>", 1, true) ~= nil)
h.check("...cut at max_brief_lines",
  req.prompt:find("truncated 40 more", 1, true) ~= nil, req.prompt)

vim.fn.writefile(padded("rewritten well below the cut"), dir .. "/MENTOR.md")
session.ask("edited out of sight")
settle()
h.check("an edit the model never saw is not re-sent",
  get().prompt:find("<project_brief>", 1, true) == nil)

-- Off switch: the copy sent at the start stands for the whole conversation.
require("mentor").setup({ context = { project_brief_refresh = false } })
session.reset()
vim.fn.writefile({ "# Cart", "", "Original." }, dir .. "/MENTOR.md")
session.ask("refresh off, first")
settle()
h.check("it still goes in once", get().prompt:find("<project_brief>", 1, true) ~= nil)
vim.fn.writefile({ "# Cart", "", "Edited." }, dir .. "/MENTOR.md")
session.ask("refresh off, after an edit")
settle()
h.check("project_brief_refresh=false ignores the edit",
  get().prompt:find("<project_brief>", 1, true) == nil)

require("mentor").setup({})
session.reset()

-------------------------------------------------------------------- MentorInit

-- A brief already exists: refuse rather than overwrite.
get = h.stub_provider()
session.init()
settle()
h.check("init refuses when a brief already exists", get() == nil)

vim.fn.delete(dir .. "/MENTOR.md")
vim.fn.delete(dir .. "/CLAUDE.md")

get = h.stub_provider()
session.init()
settle()

req = get()
h.check("init sends a request", req ~= nil)
h.check("the request names the file", req.prompt:find("MENTOR.md", 1, true) ~= nil)
h.check("system prompt carries the drafting exception",
  req.system:find("Drafting a project brief", 1, true) ~= nil)
h.check("no handback section inside the document",
  req.system:find("Handing work back", 1, true) == nil)
h.check("the draft stays out of the conversation history",
  req.state ~= session.state.provider_state)

local function buf_named(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == path then
      return b
    end
  end
  return nil
end

local buf = buf_named(root .. "/MENTOR.md")
h.check("a draft buffer exists", buf ~= nil)
h.eq("the model's text lands in the draft",
  table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "ok")
h.eq("the draft is markdown", vim.bo[buf].filetype, "markdown")
h.eq("the draft is unsaved", vim.bo[buf].modified, true)
-- The whole point: nothing is on disk until the user writes it.
h.eq("nothing reached disk", vim.fn.filereadable(root .. "/MENTOR.md"), 0)

h.check("the panel says where the draft went",
  table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
    :find("drafting into MENTOR.md", 1, true) ~= nil)

------------------------------------------------------------------ draft winbar

local function win_showing(b)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == b then
      return w
    end
  end
  return nil
end

-- An unexplained empty split for a file that does not exist reads as something
-- to close, so the window says what it is and when the writing stopped.
local draft_win = win_showing(buf)
h.check("the draft opens in its own window", draft_win ~= nil)
h.check("the winbar says the writing is over",
  vim.wo[draft_win].winbar:find("stopped writing", 1, true) ~= nil)
h.check("...and how to keep or drop it",
  vim.wo[draft_win].winbar:find("keeps MENTOR.md", 1, true) ~= nil)

brief.mark_drafting(draft_win, "MENTOR.md")
h.check("while streaming it says nothing is on disk",
  vim.wo[draft_win].winbar:find("nothing is on disk", 1, true) ~= nil)
brief.mark_done(draft_win, "MENTOR.md")

-- That's advice about an unsaved draft; once written it is just a file. The
-- event is fired by hand: a spec runs inside a VimEnter callback, so a real
-- `:write` would not trigger a nested autocmd here.
vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
h.eq("saving clears the winbar", vim.wo[draft_win].winbar, "")

-- That draft is unsaved and is the only copy, so a second run must not wipe it.
get = h.stub_provider()
session.init()
settle()
h.check("init will not clobber an unsaved draft", get() == nil)
h.eq("the draft survives the second run",
  table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "ok")

-- `bufadd()` hands back an unlisted buffer, and an unsaved draft missing from
-- `:ls` is one you cannot find by name either.
h.eq("the draft is listed", vim.bo[buf].buflisted, true)

-- Close its window and the draft is still loaded, still modified, still the
-- only copy — and now invisible. Refusing the next run has to put it back in
-- front of you; telling someone to `:bd!` a buffer they cannot see is not a way
-- out of anything.
vim.api.nvim_win_close(draft_win, true)
h.check("closing the window hides the draft", win_showing(buf) == nil)

get = h.stub_provider()
session.init()
settle()
h.check("init still refuses with the draft hidden", get() == nil)
h.check("...and brings it back into a window", win_showing(buf) ~= nil)
h.eq("...with the text intact",
  table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "ok")

vim.api.nvim_buf_delete(buf, { force = true })

---------------------------------------------------------------- MentorRevision

-- The inverse guard: nothing to revise until there is a brief.
get = h.stub_provider()
session.revise()
settle()
h.check("revise refuses when there is no brief", get() == nil)

-- Long enough that max_brief_lines would cut it: a revision has to see the end
-- of the document, or it would hand back one with the tail deleted.
local body = { "# Cart", "", "The tutor's file." }
for i = 1, 40 do
  body[#body + 1] = "point " .. i
end
body[#body + 1] = "the last line of the brief"
vim.fn.writefile(body, dir .. "/MENTOR.md")

local whole = brief.read_whole(vim.tbl_extend("force", ctx, { max_brief_lines = 5 }))
h.check("read_whole ignores max_brief_lines",
  whole.text:find("the last line of the brief", 1, true) ~= nil)
h.check("...and is not truncated", whole.text:find("truncated", 1, true) == nil)
-- Same reasoning as find(): the switch is about what every conversation
-- carries, not about a revision you asked for by name.
h.check("...and ignores project_brief=false", brief.read_whole(without("project_brief")) ~= nil)

local rev_path, rev_name, source = brief.revision_path(ctx)
h.eq("the revision lands beside the brief", rev_path, root .. "/MENTOR.md.new")
h.eq("...named after it", rev_name, "MENTOR.md.new")
h.eq("...and says what it revises", source.name, "MENTOR.md")
-- Or the draft would be picked up as the brief on the next question.
h.check("the revision is not itself a brief candidate",
  not vim.tbl_contains(ctx.project_brief_files, rev_name))

get = h.stub_provider()
session.revise()
settle()

req = get()
h.check("revise sends a request", req ~= nil)
h.check("the request carries the current brief",
  req.prompt:find("the last line of the brief", 1, true) ~= nil)
-- The brief is data here, not instruction, exactly as in a normal turn.
h.check("...wrapped as reference material",
  req.prompt:find("<project_brief>", 1, true) ~= nil)
h.check("...and named as the subject",
  req.prompt:find("Revise `MENTOR.md`", 1, true) ~= nil)
h.check("the drafting exception is in the system prompt",
  req.system:find("Drafting a project brief", 1, true) ~= nil)
h.check("the revision stays out of the conversation history",
  req.state ~= session.state.provider_state)

local rev_buf = buf_named(rev_path)
h.check("a revision buffer exists", rev_buf ~= nil)
h.eq("the model's text lands in it",
  table.concat(vim.api.nvim_buf_get_lines(rev_buf, 0, -1, false), "\n"), "ok")
h.eq("it is unsaved", vim.bo[rev_buf].modified, true)
-- The whole point, again: the brief it revises is untouched on disk.
h.eq("nothing reached disk", vim.fn.filereadable(rev_path), 0)
h.eq("the original is unchanged",
  vim.fn.readfile(root .. "/MENTOR.md")[1], "# Cart")
h.check("the panel says a revision is coming",
  table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
    :find("drafting a revision of MENTOR.md", 1, true) ~= nil)

------------------------------------------------------------------- the merge

-- `:w` on the revision would leave two briefs and the job undone, so the two
-- come up side by side instead and the winbar talks about hunks.
local rev_win = win_showing(rev_buf)
h.check("the revision opens in its own window", rev_win ~= nil)
h.eq("the revision is in diff mode", vim.wo[rev_win].diff, true)

local target_win = win_showing(buf_named(root .. "/MENTOR.md"))
h.check("the brief comes up beside it", target_win ~= nil)
h.eq("...also in diff mode", vim.wo[target_win].diff, true)
-- `do` pulls from the revision into the file being kept, so that is where the
-- cursor belongs: saving there is a save of the real brief, by hand.
h.eq("the cursor lands in the brief", vim.api.nvim_get_current_win(), target_win)

local bar = vim.wo[rev_win].winbar
-- Which spelling depends on how much room the split has, so assert the keys
-- are named rather than how they are decorated.
h.check("the winbar names the way to take all of it",
  bar:find(":MentorAccept", 1, true) ~= nil, bar)
h.check("...and offers :q! as the other ending", bar:find(":q!", 1, true) ~= nil, bar)

-- The panel is wide and says all of it, `:Dg` included.
local said = table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
h.check("the transcript names :MentorAccept", said:find(":MentorAccept", 1, true) ~= nil)
h.check("...and :Dg", said:find(":Dg", 1, true) ~= nil)
h.check("...and do", said:find("do ", 1, true) ~= nil)

-- Measured, not assumed: the long form is used where it fits.
brief.mark_merge(rev_win, "MENTOR.md", true)
local function bar_at(width)
  local saved = vim.api.nvim_win_get_width(rev_win)
  vim.api.nvim_win_set_width(rev_win, width)
  brief.mark_merge(rev_win, "MENTOR.md", true)
  local got = vim.wo[rev_win].winbar
  vim.api.nvim_win_set_width(rev_win, saved)
  brief.mark_merge(rev_win, "MENTOR.md", true)
  return got
end
-- As wide as the headless screen allows, which is not wide enough for the
-- longest spelling but is for one that names the hunk key too.
local wide = bar_at(vim.o.columns)
h.check("a wider window names `do` as well", wide:find("`do`", 1, true) ~= nil, wide)
h.check("...and does not tell you to :w the revision",
  bar:find(":w` keeps MENTOR.md.new", 1, true) == nil, bar)

-- A winbar wider than its window is scrolled, not shortened: vim keeps the
-- tail and hides the front, which is where the keys are. So the long form is
-- only ever set when it fits.
h.check("the winbar fits its window",
  vim.fn.strdisplaywidth(bar:gsub("%%#Comment#", ""):gsub("%%%*", ""))
    <= vim.api.nvim_win_get_width(rev_win), bar)

-- `do`/`dp` read a revision hunk by hunk. Taking the whole thing is the other
-- ending, and it has to mean the same from either side of the diff.
h.check("the brief can take the whole revision",
  vim.fn.getcompletion("Dg", "command")[1] ~= nil)
local target_buf = vim.api.nvim_win_get_buf(target_win)
vim.api.nvim_win_call(target_win, function() vim.cmd("Dg") end)
h.eq("...and does", table.concat(
  vim.api.nvim_buf_get_lines(target_buf, 0, -1, false), "\n"),
  table.concat(vim.api.nvim_buf_get_lines(rev_buf, 0, -1, false), "\n"))

-- The case `:%diffget` gets wrong, which is why this copies lines instead: `%`
-- is `1,$` in the *current* buffer, so a hunk that only appends past the last
-- line falls outside the range and is skipped. A revision whose one change is a
-- new final paragraph would arrive without it, silently.
vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, { "shared", "lines" })
vim.api.nvim_buf_set_lines(rev_buf, 0, -1, false, { "shared", "lines", "appended at the end" })
vim.api.nvim_win_call(target_win, function() vim.cmd("Dg") end)
h.eq("a trailing addition comes across too", table.concat(
  vim.api.nvim_buf_get_lines(target_buf, 0, -1, false), "\n"),
  "shared\nlines\nappended at the end")

-- ...and from the other side of the diff, where it is the same operation.
vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, { "shared", "lines" })
vim.api.nvim_win_call(rev_win, function() vim.cmd("Dg") end)
h.eq("the revision window takes all of it the same way", table.concat(
  vim.api.nvim_buf_get_lines(target_buf, 0, -1, false), "\n"),
  "shared\nlines\nappended at the end")

-- Both buffers go back as this section found them; the checks below read them.
vim.api.nvim_buf_set_lines(rev_buf, 0, -1, false, { "ok" })

-- Put the brief back: `Dg` leaves it modified and unsaved, exactly as `do`
-- does, and a modified buffer named MENTOR.md is a pending draft as far as the
-- next :MentorInit is concerned.
vim.api.nvim_buf_call(target_buf, function() vim.cmd("edit!") end)
h.eq("taking all of it leaves the file itself untouched", vim.bo[target_buf].modified, false)

-- Diff mode changed fold and wrap in a window we opened; closing the revision
-- is the end of the comparison and has to be the end of that too.
vim.api.nvim_win_close(rev_win, true)
vim.api.nvim_set_current_win(target_win)
h.eq("closing the revision turns diff off again", vim.wo[target_win].diff, false)

-- The same unsaved-draft guard init has, since it is now the same code.
get = h.stub_provider()
session.revise()
settle()
h.check("revise will not clobber an unsaved revision", get() == nil)
h.eq("the draft survives", table.concat(
  vim.api.nvim_buf_get_lines(rev_buf, 0, -1, false), "\n"), "ok")
vim.api.nvim_buf_delete(rev_buf, { force = true })
-- Leave the window count as this section found it, or the next check reads a
-- split it did not open as one that failed to close.
if #vim.api.nvim_list_wins() > 1 and vim.api.nvim_win_is_valid(target_win) then
  vim.api.nvim_win_close(target_win, true)
end

-- A revision already merged and written is a file like any other.
vim.fn.writefile({ "a revision I kept" }, rev_path)
get = h.stub_provider()
session.revise()
settle()
h.check("revise refuses over a revision on disk", get() == nil)
h.eq("...leaving it alone", vim.fn.readfile(rev_path)[1], "a revision I kept")
vim.fn.delete(rev_path)

-- :MentorInit is still the one that refuses when a brief is there.
get = h.stub_provider()
session.init()
settle()
h.check("init still refuses when a brief exists", get() == nil)

------------------------------------------------------------------ MentorAccept

local function disk(path)
  return table.concat(vim.fn.readfile(path), "\n")
end
local function quiet(fn)
  local real = vim.notify
  vim.notify = function() end
  local ok, a = pcall(fn)
  vim.notify = real
  assert(ok, a)
  return a
end

local brief_path = root .. "/MENTOR.md"
local before_accept = disk(brief_path)

h.eq("accept refuses with no revision to take", quiet(function() return session.accept() end), false)
h.eq("...and leaves the brief alone", disk(brief_path), before_accept)

-- Half a document is not one to accept.
get = h.stub_provider()
session.revise()
h.eq("accept refuses while the revision is still streaming",
  quiet(function() return session.accept() end), false)
settle()

rev_buf = buf_named(rev_path)
local rev_wins = vim.fn.win_findbuf(rev_buf)
target_win = win_showing(buf_named(brief_path))
h.eq("accept takes a finished revision", session.accept(), true)
h.eq("the brief on disk is the revision now", disk(brief_path), "ok")
h.eq("the brief buffer is saved, not left modified",
  vim.bo[buf_named(brief_path)].modified, false)
h.check("the revision buffer is gone", buf_named(rev_path) == nil)
h.check("...and its window", not vim.api.nvim_win_is_valid(rev_wins[1]))
h.eq("no .new reached disk", vim.fn.filereadable(rev_path), 0)
h.eq("diff mode is off in the brief's window", vim.wo[target_win].diff, false)
h.check(":Dg went with the diff", vim.fn.getcompletion("Dg", "command")[1] == nil)

-- The brief has edits of yours that taking all of it would overwrite.
vim.fn.writefile({ "# Cart", "", "mine" }, brief_path)
local tbuf = buf_named(brief_path)
vim.api.nvim_buf_call(tbuf, function() vim.cmd("edit!") end)
get = h.stub_provider()
session.revise()
settle()
vim.api.nvim_buf_set_lines(tbuf, 0, -1, false, { "# Cart", "", "mine, unsaved" })
h.eq("accept refuses over unsaved edits to the brief",
  quiet(function() return session.accept() end), false)
h.eq("...leaving them in the buffer", vim.api.nvim_buf_get_lines(tbuf, 2, 3, false)[1], "mine, unsaved")
h.eq("force takes it anyway", session.accept(true), true)
h.eq("...and saves", disk(brief_path), "ok")

-- A revision emptied by hand is not one to make the brief out of.
get = h.stub_provider()
session.revise()
settle()
vim.api.nvim_buf_set_lines(buf_named(rev_path), 0, -1, false, { "", "  " })
h.eq("accept refuses an empty revision", quiet(function() return session.accept() end), false)
h.eq("...and the brief keeps its text", disk(brief_path), "ok")
vim.api.nvim_buf_delete(buf_named(rev_path), { force = true })

-- A `.new` someone saved last time is a revision too, and once taken it would
-- otherwise block the next :MentorRevision forever.
vim.fn.writefile({ "from a saved revision" }, rev_path)
h.eq("accept takes a .new from disk", session.accept(), true)
h.eq("...into the brief", disk(brief_path), "from a saved revision")
h.eq("...and removes it", vim.fn.filereadable(rev_path), 0)

-- Off switch for the save: the take still happens, the :w stays yours.
require("mentor").setup({ context = { project_brief_accept_write = false } })
get = h.stub_provider()
session.revise()
settle()
h.eq("accept_write=false still accepts", session.accept(), true)
h.eq("...without writing", disk(brief_path), "from a saved revision")
h.eq("...leaving the brief modified", vim.bo[buf_named(brief_path)].modified, true)
h.eq("...holding the revision", vim.api.nvim_buf_get_lines(buf_named(brief_path), 0, -1, false)[1], "ok")
vim.api.nvim_buf_call(buf_named(brief_path), function() vim.cmd("edit!") end)
require("mentor").setup({})

h.check(":MentorAccept exists", vim.fn.exists(":MentorAccept") == 2)
h.check("/accept is a panel command", vim.tbl_contains(
  vim.tbl_map(function(i) return i.word end, session.commands()), "/accept"))

-------------------------------------------------------------------- brief notes

local parse = brief.parse_notes
h.eq("no section, no notes", #parse("just an answer"), 0)
local got_notes = parse(table.concat({
  "An answer.",
  "",
  "## Brief notes",
  "",
  "- The cart total is rounded in one place only.",
  "* Discounts are fractions, not percentages.",
  "",
  "## TODO(human)",
  "- `cart.py:4` — decide what an empty cart totals.",
}, "\n"))
h.eq("both notes are read", #got_notes, 2)
h.eq("...in order", got_notes[1], "The cart total is rounded in one place only.")
h.check("...and the TODO section is not one of them",
  not vim.tbl_contains(got_notes, "`cart.py:4` — decide what an empty cart totals."))
h.eq("at most three", #parse("## Brief notes\n- a\n- b\n- c\n- d\n- e"), 3)
h.eq("each is capped", #parse("## Brief notes\n- " .. ("x"):rep(1000))[1], 300)
h.eq("the last section wins",
  parse("## Brief notes\n- old\n\ntext\n\n## brief note\n- new")[1], "new")

-- A provider that answers with whatever the test wants.
local function answering(text)
  local captured
  require("mentor.provider").resolve = function()
    return {
      display_name = "stub",
      available = function() return true end,
      chat = function(o)
        captured = o
        vim.schedule(function()
          o.on_delta(text)
          o.on_done()
        end)
        return { kind = nil, kill = function() end }
      end,
    }, "claude_cli", nil
  end
  return function() return captured end
end

vim.fn.writefile({ "# Cart", "", "A teaching fixture." }, brief_path)
vim.api.nvim_buf_call(buf_named(brief_path), function() vim.cmd("edit!") end)
session.reset()

get = answering("Rounding happens last.\n\n## Brief notes\n- Totals are rounded once, at the end.\n")
session.ask("where is rounding?")
settle()
h.check("a briefed turn asks for notes",
  get().system:find("## Brief notes", 1, true) ~= nil)
h.eq("the note is collected", session.state.brief_notes[1], "Totals are rounded once, at the end.")
h.check("the panel says one is pending",
  table.concat(ui.lines(), "\n"):find("note for the brief pending", 1, true) ~= nil)
h.eq("collecting is all it does: the brief is untouched",
  disk(brief_path), "# Cart\n\nA teaching fixture.")

session.ask("and again?")
settle()
h.eq("the same note is not collected twice", #session.state.brief_notes, 1)

get = h.stub_provider()
session.revise()
settle()
req = get()
h.check("revise carries the pending notes",
  req.prompt:find("<brief_notes>", 1, true) ~= nil, req.prompt)
h.check("...with their text",
  req.prompt:find("Totals are rounded once", 1, true) ~= nil)
h.check("a draft does not ask for notes about itself",
  req.system:find("## Brief notes", 1, true) == nil)

-- A note arriving while you read the revision did not go into it.
get = answering("## Brief notes\n- Discounts are fractions.\n")
session.ask("what is discount?")
settle()
h.eq("two notes pending", #session.state.brief_notes, 2)
h.eq("accepting the revision", session.accept(), true)
h.eq("...retires the note it folded in, and only that one",
  session.state.brief_notes[1], "Discounts are fractions.")
h.eq("...leaving one", #session.state.brief_notes, 1)

session.notes("drop")
h.eq("/notes drop forgets them", #session.state.brief_notes, 0)

require("mentor").setup({ context = { project_brief_notes = false } })
get = h.stub_provider()
session.ask("notes off")
settle()
h.check("project_brief_notes=false stops asking",
  get().system:find("## Brief notes", 1, true) == nil)
require("mentor").setup({})

get = answering("## Brief notes\n- Something.\n")
session.ask("one more")
settle()
session.reset()
h.eq("reset drops the notes with the conversation", #session.state.brief_notes, 0)

vim.fn.delete(brief_path)
get = h.stub_provider()
session.ask("no brief at all")
settle()
h.check("with no brief there is nothing to take notes against",
  get().system:find("## Brief notes", 1, true) == nil)

-- Accepting leaves you in the brief, on purpose, so every revision above left a
-- window on it. Put the layout back the way the sections below expect it.
local leftover = buf_named(brief_path)
if leftover then
  for _, w in ipairs(vim.fn.win_findbuf(leftover)) do
    if #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(w, true)
    end
  end
  vim.api.nvim_buf_delete(leftover, { force = true })
end
vim.fn.writefile({ "# Cart" }, brief_path)

vim.fn.delete(dir .. "/MENTOR.md")

-- A backend that answers with nothing leaves an empty buffer for a file that
-- does not exist — clutter you would have to work out before closing.
require("mentor.provider").resolve = function()
  return {
    display_name = "silent",
    available = function() return true end,
    chat = function(o)
      vim.schedule(o.on_done)
      return { kill = function() end }
    end,
  }, "claude_cli", nil
end
local before = #vim.api.nvim_list_wins()
session.init()
settle()
h.eq("a silent answer leaves no draft window", #vim.api.nvim_list_wins(), before)
h.check("...and no empty draft buffer", buf_named(root .. "/MENTOR.md") == nil)

-- A backend that never starts must not leave an empty split behind.
require("mentor.provider").resolve = function()
  return nil, nil, "no backend"
end
local wins = #vim.api.nvim_list_wins()
local real_notify = vim.notify -- an ERROR notify is noise in headless output
vim.notify = function() end
session.init()
settle()
vim.notify = real_notify
h.eq("a failed start leaves no draft window", #vim.api.nvim_list_wins(), wins)
h.check("...and no draft buffer", buf_named(root .. "/MENTOR.md") == nil)

h.check("outside a repo init reports rather than raising", pcall(function()
  vim.cmd("enew")
  local plain = vim.fn.tempname()
  vim.fn.mkdir(plain, "p")
  vim.cmd("cd " .. vim.fn.fnameescape(plain))
  context.last_code_buf = nil
  session.init()
  h.cleanup(plain)
end))

h.cleanup(dir)
