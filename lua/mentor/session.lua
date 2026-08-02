local config = require("mentor.config")
local context = require("mentor.context")
local prompts = require("mentor.prompts")
local provider = require("mentor.provider")
local ui = require("mentor.ui")

local M = {}

M.state = {
  busy = false,
  handle = nil,
  provider_name = nil,
  provider_state = {}, -- session_id (CLI) or message history (HTTP)
  pending_selection = nil, -- code attached to the next message
  briefed_root = nil, -- repo whose project brief this conversation has seen
  shown_model = nil, -- model named in the transcript most recently
}

local function notify(msg, level)
  vim.notify("[mentor] " .. msg, level or vim.log.levels.INFO)
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
  end
  M.state.provider_name = name

  local root = context.git_root() or vim.fn.getcwd()

  -- The project brief goes in once per conversation, and again if you move to
  -- another repo mid-session: the root follows the last code buffer, not cwd.
  -- A side request carrying its own state (:MentorInit) is not a conversation
  -- and gets none of this.
  local briefing = nil
  if not opts.state then
    local brief = require("mentor.brief").read(cfg.context)
    if brief and M.state.briefed_root ~= root then
      briefing = root
      prompt = prompts.brief(brief) .. "\n\n" .. prompt
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
        M.state.briefed_root = briefing
      end
      if not got_output then
        ui.append("(no response)\n")
      end
      ui.append("\n")
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

--- Draft a project brief for this repo.
---
--- The draft streams into an unsaved buffer; nothing reaches disk until you
--- save it. Refuses when a brief already exists — overwriting one is a job for
--- you and your editor, not for the model.
function M.init()
  local cfg = config.get()
  local brief = require("mentor.brief")

  if not context.git_root() then
    notify("not inside a git repository", vim.log.levels.WARN)
    return
  end

  local existing = brief.find(cfg.context)
  if existing then
    notify(existing.name .. " already exists — mentor reads it at the start of a conversation")
    return
  end

  local path, name = brief.target_path(cfg.context)
  if not path then
    notify("nowhere to write a brief", vim.log.levels.WARN)
    return
  end

  local pending = brief.pending_draft(path)
  if pending then
    notify(("an unsaved %s draft is already open — `:w` it or `:bd!` it first"):format(name))
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == pending then
        vim.api.nvim_set_current_win(w)
        break
      end
    end
    return
  end

  local buf, win = brief.open_draft(path)
  brief.mark_drafting(win, name)

  local started = send(prompts.init_brief(name), "Draft " .. name .. " for this project.", {
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
        brief.mark_done(win, name)
        notify(name .. " drafted — read it, then :w to keep it")
      elseif brief.is_empty(buf) then
        -- Nothing came back, so the split is an empty buffer for a file that
        -- does not exist. The panel already said what went wrong; leaving the
        -- window behind only invites you to wonder what it is.
        brief.discard_draft(buf, win)
      else
        brief.mark_done(win, name)
      end
    end,
  })

  if not started then
    brief.discard_draft(buf, win)
    return
  end
  ui.append("drafting into " .. name .. " — read it, then `:w` to keep it.\n")
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
function M.reset()
  if M.state.busy then
    M.stop()
  end
  M.state.provider_state = {}
  M.state.provider_name = nil
  M.state.pending_selection = nil
  M.state.briefed_root = nil -- the next conversation gets the brief again
  M.state.shown_model = nil -- ...and re-states which model is answering
  ui.set_pending(nil)
  ui.clear()
  notify("conversation reset")
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

return M
