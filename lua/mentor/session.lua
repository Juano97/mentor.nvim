local config = require("mentor.config")
local context = require("mentor.context")
local prompts = require("mentor.prompts")
local provider = require("mentor.provider")
local store = require("mentor.store")
local ui = require("mentor.ui")

local M = {}

M.state = {
  busy = false,
  handle = nil,
  provider_name = nil,
  provider_state = {}, -- session_id (CLI) or message history (HTTP)
  pending_selection = nil, -- code attached to the next message
  briefed_root = nil, -- repo whose project brief this conversation has seen
  briefed_stamp = nil, -- ...and a hash of the version that went in
  shown_model = nil, -- model named in the transcript most recently
  conversation = nil, -- the saved record this conversation writes to
}

local function notify(msg, level)
  vim.notify("[mentor] " .. msg, level or vim.log.levels.INFO)
end

--- Record the turn that just finished, so a later nvim can resume it.
---
--- Written per turn rather than on exit: nvim does not always get to say
--- goodbye, and the whole point is surviving the times it doesn't.
---@param root string
---@param name string backend
---@param echo string what the user asked, for the title
local function remember(root, name, echo)
  local cfg = config.get()
  if not cfg.history or cfg.history.save == false then
    return
  end

  local conv = M.state.conversation
  if not conv or conv.root ~= root then
    conv = { id = store.new_id(), root = root, started = store.now(), turns = 0 }
    M.state.conversation = conv
  end

  -- The opening question names the conversation in the picker; later ones
  -- would only rename it out from under you.
  if not conv.title or conv.title == "" then
    conv.title = vim.trim((echo:gsub("%s+", " "))):sub(1, 60)
  end

  conv.turns = (conv.turns or 0) + 1
  conv.updated = store.now()
  conv.provider = name
  conv.provider_state = M.state.provider_state
  conv.model = cfg[name] and cfg[name].model or nil
  conv.briefed = M.state.briefed_root
  conv.briefed_stamp = M.state.briefed_stamp
  conv.lines = ui.lines()

  store.save(cfg.history, conv)
end

--- @param prompt string what the model sees
--- @param echo string what the user sees in the panel
--- @param opts table|nil { sink, system, todos, state, on_done } see M.init
--- @return boolean started false when nothing was sent
local function send(prompt, echo, opts)
  if M.state.busy then
    notify("still answering — :MentorStop to cancel", vim.log.levels.WARN)
    return false
  end

  opts = opts or {}
  local cfg = config.get()
  local impl, name, err = provider.resolve(cfg)
  if not impl then
    notify(err, vim.log.levels.ERROR)
    return false
  end

  -- Switching backends invalidates the conversation handle, and with it
  -- everything the old session had already been told.
  if M.state.provider_name and M.state.provider_name ~= name then
    M.state.provider_state = {}
    M.state.briefed_root = nil
    M.state.briefed_stamp = nil
  end
  M.state.provider_name = name

  local root = context.git_root() or vim.fn.getcwd()

  -- The project brief goes in once per conversation, again if you move to
  -- another repo mid-session (the root follows the last code buffer, not cwd),
  -- and again if the file itself is edited. That last one needs the hash: the
  -- root alone cannot tell "same file, new contents", which is why editing a
  -- brief used to do nothing until :MentorReset. It is taken over `brief.text`,
  -- i.e. after truncation, so it tracks what was actually sent -- an edit below
  -- `max_brief_lines` that the model never saw does not spend a turn re-sending.
  --
  -- A side request carrying its own state (:MentorInit) is not a conversation
  -- and gets none of this.
  local briefing = nil
  if not opts.state then
    local brief = require("mentor.brief").read(cfg.context)
    if brief then
      local stamp = vim.fn.sha256(brief.text)
      local refresh = cfg.context.project_brief_refresh ~= false
      local stale = refresh and M.state.briefed_stamp ~= stamp
      if M.state.briefed_root ~= root or stale then
        -- Same repo means it was already sent once, so this copy supersedes
        -- rather than introduces. Moving to another repo introduces.
        briefing = { root = root, stamp = stamp }
        prompt = prompts.brief(brief, M.state.briefed_root == root) .. "\n\n" .. prompt
      end
    end
  end

  ui.open(cfg.window)
  ui.header("user")
  ui.append(echo .. "\n")

  -- Name the model on the first answer and at every switch after that, so the
  -- transcript says who said what without carrying a suffix on every turn.
  local model = cfg[name].model
  local announce = model ~= M.state.shown_model
  M.state.shown_model = model
  ui.header("mentor", announce and model or nil)

  M.state.busy = true
  ui.set_status("busy")
  local got_output = false

  local system = opts.system or prompts.system
  if opts.todos ~= false and cfg.learning and cfg.learning.todos then
    system = system .. prompts.todo_instructions
  end

  -- Deltas land in the transcript unless a caller redirects them (:MentorInit
  -- streams into a draft buffer instead).
  local sink = opts.sink or ui.append

  M.state.handle = impl.chat({
    prompt = prompt,
    system = system,
    state = opts.state or M.state.provider_state,
    cfg = cfg[name],
    cwd = root,

    on_delta = function(text)
      got_output = true
      sink(text)
    end,

    on_error = function(msg)
      ui.append("\n⚠ " .. tostring(msg) .. "\n")
      notify(tostring(msg), vim.log.levels.ERROR)
    end,

    on_done = function()
      M.state.busy = false
      M.state.handle = nil
      ui.set_status("idle")
      -- Only mark the brief as delivered once something came back: a request
      -- that died before the backend answered never recorded it either.
      if briefing and got_output then
        M.state.briefed_root = briefing.root
        M.state.briefed_stamp = briefing.stamp
      end
      if not got_output then
        ui.append("(no response)\n")
      end
      ui.append("\n")
      -- A side request carrying its own state (:MentorInit) is not part of the
      -- conversation and has nothing to resume.
      if got_output and not opts.state then
        remember(root, name, echo)
      end
      if opts.on_done then
        opts.on_done(got_output)
      end
    end,
  })

  return true
end

--- Free-form question. With no text, opens the panel and drops you in the
--- input box so you can just type.
---@param question string|nil
function M.ask(question)
  if not (question and vim.trim(question) ~= "") then
    ui.focus_input(config.get().window)
    return
  end

  local q = vim.trim(question)

  -- A selection captured earlier rides along with this message, then clears.
  local selection = M.state.pending_selection
  M.state.pending_selection = nil
  ui.set_pending(nil)

  local echo = q
  if selection then
    echo = ("%s\n(about %s:%d-%d)"):format(q, selection.path, selection.first, selection.last)
  end

  send(prompts.ask(q, context.cursor_context(), selection), echo)
end

--- Attach an explicit line range to the next message.
---@param first integer
---@param last integer
---@param question string|nil send immediately when given
function M.ask_range(first, last, question)
  local cfg = config.get()
  local selection = context.selection(first, last, cfg.context)
  if not selection then
    notify("nothing to select here", vim.log.levels.WARN)
    return
  end

  M.state.pending_selection = selection
  ui.open(cfg.window)
  ui.set_pending(("%s:%d-%d"):format(selection.path, selection.first, selection.last))

  if question and vim.trim(question) ~= "" then
    M.ask(question)
  else
    ui.focus_input(cfg.window)
  end
end

--- Attach the current visual selection to the next message.
function M.ask_selection()
  local cfg = config.get()
  local selection = context.visual_selection(cfg.context)
  if not selection then
    notify("no visual selection", vim.log.levels.WARN)
    return
  end
  M.ask_range(selection.first, selection.last)
end

--- Open the panel and put the cursor in the input box.
function M.focus_input()
  ui.focus_input(config.get().window)
end

--- Review the most recent changes.
function M.review()
  local cfg = config.get()
  local diff, label = context.recent_changes(cfg.context)
  if not diff then
    notify(label, vim.log.levels.WARN)
    return
  end
  send(prompts.review(diff, label), "Review my recent changes (" .. label .. ").")
end

--- Stream a document into an unsaved buffer for `path`, and leave the keeping
--- of it to the user.
---
--- Shared by `:MentorInit` and `:MentorRevision`, which differ only in what
--- they ask for: the same buffer-not-file bargain, the same winbar, the same
--- cleanup when nothing came back. `path` must not exist on disk — both
--- callers check that, and it is the whole reason this streams into a buffer.
---@param spec table { path, name, prompt, echo, note, on_drafted }
---@return boolean started
local function draft(spec)
  local brief = require("mentor.brief")

  local pending = brief.pending_draft(spec.path)
  if pending then
    -- Show it rather than talk about it: the buffer holds the only copy of the
    -- text, and it may well be hidden, which is how someone ends up told to
    -- `:bd!` a buffer they cannot find. The number goes in the message so the
    -- other ending is one paste away.
    brief.show_draft(pending)
    notify(("an unsaved %s draft is already open (buffer %d) — `:w` it to keep it, or `:bd! %d` to drop it")
      :format(spec.name, pending, pending))
    return false
  end

  local buf, win = brief.open_draft(spec.path)
  brief.mark_drafting(win, spec.name)

  local started = send(spec.prompt, spec.echo, {
    system = prompts.system .. prompts.brief_instructions,
    todos = false, -- a handback section has no business inside the document
    -- A fresh state: a whole document sitting in the history would follow the
    -- conversation around for no benefit.
    state = {},
    sink = function(text)
      brief.append(buf, text)
    end,
    on_done = function(got_output)
      if got_output then
        if spec.on_drafted then
          spec.on_drafted(buf, win)
        else
          brief.mark_done(win, spec.name)
          notify(spec.name .. " drafted — read it, then :w to keep it")
        end
      elseif brief.is_empty(buf) then
        -- Nothing came back, so the split is an empty buffer for a file that
        -- does not exist. The panel already said what went wrong; leaving the
        -- window behind only invites you to wonder what it is.
        brief.discard_draft(buf, win)
      else
        brief.mark_done(win, spec.name)
      end
    end,
  })

  if not started then
    brief.discard_draft(buf, win)
    return false
  end

  ui.append((spec.note or ("drafting into " .. spec.name ..
    " — read it, then `:w` to keep it.")) .. "\n")
  return true
end

--- Draft a project brief for this repo.
---
--- The draft streams into an unsaved buffer; nothing reaches disk until you
--- save it. Refuses when a brief already exists — overwriting one is a job for
--- you and your editor, not for the model; `:MentorRevision` is the way to have
--- the model propose one.
function M.init()
  local cfg = config.get()
  local brief = require("mentor.brief")

  if not context.git_root() then
    notify("not inside a git repository", vim.log.levels.WARN)
    return
  end

  local existing = brief.find(cfg.context)
  if existing then
    notify(("%s already exists — :MentorRevision drafts a revision beside it")
      :format(existing.name))
    return
  end

  local path, name = brief.target_path(cfg.context)
  if not path then
    notify("nowhere to write a brief", vim.log.levels.WARN)
    return
  end

  draft({ path = path, name = name, prompt = prompts.init_brief(name),
    echo = "Draft " .. name .. " for this project." })
end

--- Revise the brief that is already there, into a second file beside it.
---
--- The inverse guard to `init`: that one refuses when the brief exists, this
--- one refuses when it does not. Neither ever writes over a file — a revision
--- lands in `MENTOR.md.new` for you to diff, and merging the two is yours.
function M.revise()
  local cfg = config.get()
  local brief = require("mentor.brief")

  if not context.git_root() then
    notify("not inside a git repository", vim.log.levels.WARN)
    return
  end

  local source = brief.read_whole(cfg.context)
  if not source then
    notify("no project brief here yet — :MentorInit drafts one", vim.log.levels.WARN)
    return
  end

  local path, name = brief.revision_path(cfg.context)
  if vim.fn.filereadable(path) == 1 then
    notify(("%s is already on disk — merge or delete it first"):format(name),
      vim.log.levels.WARN)
    return
  end

  local diff = cfg.context.project_brief_diff ~= false
  local take = cfg.context.project_brief_diff_cmd
  if take == false or take == "" then
    take = nil
  end

  draft({
    path = path,
    name = name,
    prompt = prompts.revise_brief(source.name, source.text),
    echo = "Revise " .. source.name .. " against the project as it is now.",
    -- Not "`:w` to keep it": saving the revision would leave two briefs on
    -- disk and the actual job undone. What you want out of it is hunks.
    note = diff
      and ("drafting a revision of %s — it opens in a diff when it lands, and `do` on a hunk takes it."):format(source.name)
      or ("drafting a revision of %s into %s — diff the two when it lands."):format(
        source.name, name),
    on_drafted = function(_, win)
      local brief = require("mentor.brief")
      local diffing = diff and brief.open_diff(win, source.path, take)
      brief.mark_merge(win, source.name, diffing, take)

      -- The winbar says this too, but it is one line in a window narrow enough
      -- to cut it in half. The panel is wide, it scrolls, and it is where you
      -- were already reading — so the keys go here as well, and stay findable
      -- after you have forgotten them.
      if diffing then
        ui.ensure_blank_line()
        local keys = { "▍merging the revision" }
        if take then
          keys[#keys + 1] = ("%-12s take the whole revision"):format(":" .. take)
        end
        vim.list_extend(keys, {
          ("%-12s take the hunk under the cursor"):format("do"),
          ("%-12s next / previous change"):format("]c  [c"),
          ("%-12s save %s — the only write in any of this"):format(":w", source.name),
          ("%-12s close the revision and keep nothing else"):format(":q!"),
          "",
          "",
        })
        ui.append(table.concat(keys, "\n"))
        ui.scroll_to_end()
      end

      notify(diffing
        and (take
          and ("revision ready — :%s takes all of it into %s, `:q!` discards the rest")
            :format(take, source.name)
          or ("revision ready — `do` takes a hunk into %s, `:q!` discards the rest")
            :format(source.name))
        or ("revision drafted into %s — diff it against %s"):format(name, source.name))
    end,
  })
end

function M.stop()
  if not M.state.busy or not M.state.handle then
    notify("nothing running")
    return
  end
  pcall(function()
    M.state.handle:kill(15) -- SIGTERM
  end)
  notify("cancelled")
end

--- Drop conversation history and clear the panel.
---
--- The conversation that was running stays on disk under its own entry: reset
--- starts the next one, it does not erase the last one. `:MentorResume` is how
--- you get it back.
function M.reset()
  if M.state.busy then
    M.stop()
  end
  M.state.provider_state = {}
  M.state.provider_name = nil
  M.state.pending_selection = nil
  M.state.briefed_root = nil -- the next conversation gets the brief again
  M.state.briefed_stamp = nil
  M.state.shown_model = nil -- ...and re-states which model is answering
  M.state.conversation = nil -- ...and is saved as a conversation of its own
  ui.set_pending(nil)
  ui.clear()
  notify("conversation reset")
end

--- Saved conversations for the repo you are working in, newest first.
---@return table[] records, string root
function M.saved()
  local cfg = config.get()
  local root = context.git_root() or vim.fn.getcwd()
  return store.list(cfg.history or {}, root), root
end

--- Load a saved conversation into the panel and hand it back to the backend.
---@param conv table a record from `M.saved()`
local function restore(conv)
  local cfg = config.get()

  M.state.provider_state = conv.provider_state or {}
  M.state.provider_name = conv.provider
  M.state.briefed_root = conv.briefed -- it has already been told, once
  -- Records written before briefs were versioned have no stamp, so the next
  -- turn re-sends once. Resuming a thread whose brief may have moved on since
  -- is exactly when that is the right call.
  M.state.briefed_stamp = conv.briefed_stamp
  M.state.shown_model = conv.model
  M.state.pending_selection = nil
  M.state.conversation = conv

  -- Before the transcript goes in, not after: filling a buffer that has no
  -- window leaves the view at line 1 when one finally opens, and a resumed
  -- conversation would land you at the top of a thread you have already read.
  ui.open(cfg.window)

  ui.set_pending(nil)
  ui.replace(conv.lines or {})
  ui.ensure_blank_line()
  ui.append(("▍resumed — %s, %d turn%s\n\n"):format(
    store.ago(conv.updated), conv.turns or 0, (conv.turns or 0) == 1 and "" or "s"))

  -- Answering from a different backend than the one that was talking means a
  -- fresh conversation on the next question: `send` clears the handle when the
  -- name changes. Say so now rather than let it be a surprise.
  local _, name = provider.resolve(cfg)
  if name and conv.provider and name ~= conv.provider then
    ui.append(("(%s answered this; %s will start over from here)\n\n"):format(
      conv.provider, name))
  end

  -- The end of the conversation is where you left off, so that is what the
  -- panel shows. `follow()` would decline once the panel is the current window.
  ui.scroll_to_end()
  ui.focus_input(cfg.window)
  notify(("resumed: %s"):format(conv.title or conv.id))
end

--- Pick up a conversation saved by an earlier session.
---@param which string|nil index into `M.saved()`, 1 being the most recent;
---                        omitted opens a picker
function M.resume(which)
  if M.state.busy then
    notify("still answering — :MentorStop first", vim.log.levels.WARN)
    return
  end

  local saved, root = M.saved()
  if #saved == 0 then
    notify(("no saved conversations for %s"):format(vim.fn.fnamemodify(root, ":t")))
    return
  end

  if which and vim.trim(which) ~= "" then
    local n = tonumber(which)
    if not n or not saved[n] then
      notify(("no conversation %s — there are %d"):format(which, #saved), vim.log.levels.WARN)
      return
    end
    restore(saved[n])
    return
  end

  -- vim.ui.select rather than a window of our own: whatever picker the user
  -- has already wired up is the one they want.
  vim.ui.select(saved, {
    prompt = "Resume a mentor conversation",
    format_item = store.describe,
  }, function(choice)
    if choice then
      restore(choice)
    end
  end)
end

------------------------------------------------------------- panel commands

---@type table<string, MentorCommand>
local COMMANDS -- forward declaration: the helpers below close over it

--- Command names in a fixed order. `pairs` over a table is not one, and a help
--- list that reshuffles itself between calls is a list you cannot skim.
---@return string[]
local function sorted_names()
  local names = vim.tbl_keys(COMMANDS)
  table.sort(names)
  return names
end

---@param entry MentorCommand
---@return string[]
local function sorted_forms(entry)
  local forms = vim.tbl_keys(entry.forms or {})
  table.sort(forms)
  return forms
end

--- What you can type in the input box instead of a question. The panel is
--- where you already are: reaching for `:MentorResume` means leaving it, and
--- the cursor was in the box for a reason.
---
--- `/resume` takes the most recent conversation rather than opening the picker
--- the way `:MentorResume` does — from in here you are usually carrying on
--- from the last thing you were doing, and `/resume list` is the picker.
---
--- One table, three readers: `submit` dispatches on it, `/help` prints it and
--- the input box completes from it. A hand-written copy in any of the three
--- would be the one that goes stale. `forms` are the extra spellings worth
--- showing a reader — they are not separate commands, so they stay out of
--- completion, which offers the bare name and lets you type the argument.
---@class MentorCommand
---@field desc string one line, for `/help` and the completion menu
---@field forms string[]|nil argument spellings `/help` should also list
---@field run fun(args: string)
COMMANDS = {
  resume = {
    desc = "the most recent conversation here",
    forms = {
      ["/resume 2"] = "…or the second most recent",
      ["/resume list"] = "choose from all of them",
    },
    run = function(args)
      if args == "list" or args == "?" then
        M.resume(nil)
      else
        M.resume(args ~= "" and args or "1")
      end
    end,
  },
  revise = {
    desc = "draft a revision of the project brief",
    run = function() M.revise() end,
  },
  reset = {
    desc = "start a new conversation",
    run = function() M.reset() end,
  },
  stop = {
    desc = "cancel the answer in flight",
    run = function() M.stop() end,
  },
  help = {
    desc = "list these commands",
    run = function()
      ui.open(config.get().window)
      ui.ensure_blank_line()

      local out = { "▍panel commands" }
      for _, name in ipairs(sorted_names()) do
        local entry = COMMANDS[name]
        out[#out + 1] = ("%-14s %s"):format("/" .. name, entry.desc)
        for _, form in ipairs(sorted_forms(entry)) do
          out[#out + 1] = ("%-14s %s"):format(form, entry.forms[form])
        end
      end
      out[#out + 1] = ""
      out[#out + 1] = ""

      ui.append(table.concat(out, "\n"))
      ui.scroll_to_end()
    end,
  },
}

--- A line typed in the input box: a command if it is one, otherwise a question.
---
--- The name has to be a bare word — `/usr/bin/env, what is it?` is a question
--- about a path, not a mistyped command. Anything that *does* look like a
--- command but isn't one is refused rather than sent, so a typo costs a
--- correction instead of a turn.
---@param text string
---@return boolean handled false to leave the text in the input box
function M.submit(text)
  local name, args = text:match("^/([%a][%w_-]*)%s+(.*)$")
  if not name then
    name, args = text:match("^/([%a][%w_-]*)$"), ""
  end

  if not name then
    M.ask(text)
    return true
  end

  local command = COMMANDS[name:lower()]
  if not command then
    notify(("no /%s here — /help lists what there is"):format(name), vim.log.levels.WARN)
    return false
  end

  command.run(vim.trim(args))
  return true
end

--- Completion candidates for the input box, in `complete()` item form.
---
--- Only the bare names: `/resume list` is an argument to `/resume`, and a menu
--- that offered both would be inviting you to pick a spelling rather than a
--- command. `/help` is where the argument forms are written down.
---@return table[] items { word = "/reset", menu = "start a new conversation" }
function M.commands()
  local items = {}
  for _, name in ipairs(sorted_names()) do
    items[#items + 1] = { word = "/" .. name, menu = COMMANDS[name].desc }
  end
  return items
end

function M.toggle()
  ui.toggle(config.get().window)
end

--- The model for whichever backend would answer right now.
---@return string|nil model, string|nil backend
function M.model()
  local cfg = config.get()
  local _, backend = provider.resolve(cfg)
  if not backend then
    return nil, nil
  end
  return cfg[backend].model, backend
end

--- Completion candidates for :MentorModel. Suggestions only — `set_model`
--- accepts anything, because the backend is the authority on what exists.
---@return string[]
function M.models()
  local cfg = config.get()
  local _, backend = provider.resolve(cfg)
  return backend and vim.deepcopy(cfg[backend].models or {}) or {}
end

--- Point the active backend at a different model.
---
--- Takes effect on the next turn and leaves the conversation intact: every turn
--- spawns a fresh process (or a fresh POST) and passes the model then, so
--- unlike a backend switch there is no session state to invalidate.
---@param name string|nil omit to report the current model
---@return string|nil model
function M.set_model(name)
  local cfg = config.get()
  local _, backend, err = provider.resolve(cfg)
  if not backend then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  local bcfg = cfg[backend]

  local function describe()
    return bcfg.model or "the claude CLI's own default"
  end

  if not (name and vim.trim(name) ~= "") then
    notify(("%s model: %s"):format(backend, describe()))
    return bcfg.model
  end

  name = vim.trim(name)

  -- "default" is the only way back to nil, i.e. deferring to the CLI again.
  -- The HTTP backend has nothing to defer to: the model goes in the body.
  if name == "default" then
    if backend ~= "claude_cli" then
      notify("this backend needs an explicit model", vim.log.levels.WARN)
      return bcfg.model
    end
    bcfg.model = nil
  else
    bcfg.model = name
  end

  notify("model: " .. describe())
  return bcfg.model
end

--- Turn learning-mode TODOs on or off for subsequent turns.
---@param enable boolean|nil omit to flip
---@return boolean state
function M.toggle_todos(enable)
  local learning = config.get().learning
  if enable == nil then
    learning.todos = not learning.todos
  else
    learning.todos = enable and true or false
  end
  notify("learning TODOs " .. (learning.todos and "on" or "off"))
  return learning.todos
end

--- Insert TODO(human) markers as comments in your own buffers.
--- With the cursor on a TODO line inside the panel, inserts just that item;
--- otherwise inserts every item from the most recent TODO block.
function M.insert_todos()
  local todo = require("mentor.todo")
  local buf = ui.state.buf

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    notify("no conversation yet", vim.log.levels.WARN)
    return
  end

  local items
  if ui.win_valid() and vim.api.nvim_get_current_win() == ui.state.win then
    local one = todo.parse_line(vim.api.nvim_get_current_line())
    if one then
      items = { one }
    end
  end
  items = items or todo.parse_last_block(buf)

  if #items == 0 then
    notify("no TODO(human) items found", vim.log.levels.WARN)
    return
  end

  local inserted, errors = todo.insert_all(items)
  if inserted > 0 then
    notify(("inserted %d marker%s"):format(inserted, inserted == 1 and "" or "s"))
  end
  for _, err in ipairs(errors) do
    notify(err, vim.log.levels.WARN)
  end
end

--- Delete the marker comments again once you have worked through them.
--- The buffer you are working in by default; `all` sweeps the repo.
---@param all boolean|nil
function M.clear_todos(all)
  local todo = require("mentor.todo")

  -- Deliberately symmetrical with insert_todos: buffers are left modified and
  -- unsaved, so nothing reaches disk without a keystroke of yours.
  if all then
    local removed, buffers, errors = todo.clear_all()
    if removed == 0 then
      notify("no TODO(human) markers in this repo")
    else
      notify(("removed %d marker%s in %d buffer%s (unsaved: :wa to keep)"):format(
        removed, removed == 1 and "" or "s", buffers, buffers == 1 and "" or "s"))
    end
    for _, err in ipairs(errors) do
      notify(err, vim.log.levels.WARN)
    end
    return
  end

  local buf = context.code_buf()
  if not buf then
    notify("no file buffer to clear", vim.log.levels.WARN)
    return
  end

  local removed, err = todo.clear(buf)
  if err then
    notify(err, vim.log.levels.WARN)
  elseif removed == 0 then
    notify("no TODO(human) markers here")
  else
    notify(("removed %d marker%s (unsaved: :w to keep)")
      :format(removed, removed == 1 and "" or "s"))
  end
end

return M
