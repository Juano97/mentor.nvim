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
}

local function notify(msg, level)
  vim.notify("[mentor] " .. msg, level or vim.log.levels.INFO)
end

--- @param prompt string what the model sees
--- @param echo string what the user sees in the panel
local function send(prompt, echo)
  if M.state.busy then
    notify("still answering — :MentorStop to cancel", vim.log.levels.WARN)
    return
  end

  local cfg = config.get()
  local impl, name, err = provider.resolve(cfg)
  if not impl then
    notify(err, vim.log.levels.ERROR)
    return
  end

  -- Switching backends invalidates the conversation handle.
  if M.state.provider_name and M.state.provider_name ~= name then
    M.state.provider_state = {}
  end
  M.state.provider_name = name

  ui.open(cfg.window)
  ui.header("user")
  ui.append(echo .. "\n")
  ui.header("mentor")

  M.state.busy = true
  ui.set_status("busy")
  local got_output = false

  local system = prompts.system
  if cfg.learning and cfg.learning.todos then
    system = system .. prompts.todo_instructions
  end

  M.state.handle = impl.chat({
    prompt = prompt,
    system = system,
    state = M.state.provider_state,
    cfg = cfg[name],
    cwd = context.git_root() or vim.fn.getcwd(),

    on_delta = function(text)
      got_output = true
      ui.append(text)
    end,

    on_error = function(msg)
      ui.append("\n⚠ " .. tostring(msg) .. "\n")
      notify(tostring(msg), vim.log.levels.ERROR)
    end,

    on_done = function()
      M.state.busy = false
      M.state.handle = nil
      ui.set_status("idle")
      if not got_output then
        ui.append("(no response)\n")
      end
      ui.append("\n")
    end,
  })
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
  ui.set_pending(nil)
  ui.clear()
  notify("conversation reset")
end

function M.toggle()
  ui.toggle(config.get().window)
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
