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

-- That draft is unsaved and is the only copy, so a second run must not wipe it.
get = h.stub_provider()
session.init()
settle()
h.check("init will not clobber an unsaved draft", get() == nil)
h.eq("the draft survives the second run",
  table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "ok")

vim.api.nvim_buf_delete(buf, { force = true })

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
