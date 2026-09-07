local config = require("mentor.config")
local session = require("mentor.session")

local M = {}

---@param opts table|nil see lua/mentor/config.lua for defaults
function M.setup(opts)
  local cfg = config.setup(opts)
  require("mentor.context").setup()

  local function map(lhs, fn, desc)
    if lhs and lhs ~= false and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { desc = "Mentor: " .. desc, silent = true })
    end
  end

  local k = cfg.keymaps or {}
  map(k.toggle, M.toggle, "toggle panel")
  map(k.ask, function() M.ask() end, "ask a question")

  -- Same key in visual mode attaches the selection to the next question.
  if k.ask and k.ask ~= false and k.ask ~= "" then
    vim.keymap.set("x", k.ask, M.ask_selection,
      { desc = "Mentor: ask about selection", silent = true })
  end

  map(k.review, M.review, "review recent changes")
  map(k.stop, M.stop, "cancel current answer")
  map(k.reset, M.reset, "reset conversation")
  map(k.todos, function() M.toggle_todos() end, "toggle learning TODOs")
  map(k.todo_insert, M.insert_todos, "insert TODO markers")
  map(k.todo_clear, function() M.clear_todos() end, "clear TODO markers here")

  return M
end

---@param question string|nil omit to open the input box
function M.ask(question)
  session.ask(question)
end

--- Attach the current visual selection to the next question.
function M.ask_selection()
  session.ask_selection()
end

--- Attach an explicit line range to the next question.
---@param first integer
---@param last integer
---@param question string|nil send immediately when given
function M.ask_range(first, last, question)
  session.ask_range(first, last, question)
end

function M.review()
  session.review()
end

--- Draft a project brief into a buffer you review and save yourself.
function M.init()
  session.init()
end

--- Draft a revision of the existing brief, into a file beside it.
function M.revise()
  session.revise()
end

--- Point the active backend at a different model, from the next turn on.
---@param name string|nil omit to report the current one; "default" to unset
---@return string|nil model
function M.set_model(name)
  return session.set_model(name)
end

--- The model the active backend would use.
---@return string|nil model, string|nil backend
function M.model()
  return session.model()
end

--- Completion candidates for :MentorModel.
---@return string[]
function M.models()
  return session.models()
end

function M.toggle()
  session.toggle()
end

function M.stop()
  session.stop()
end

function M.reset()
  session.reset()
end

--- Pick up a conversation from an earlier nvim.
---@param which string|nil index, 1 being the most recent; omitted picks
function M.resume(which)
  session.resume(which)
end

--- Saved conversations for the repo you are working in, newest first.
---@return table[]
function M.saved()
  return (session.saved())
end

--- Toggle learning-mode TODO(human) items.
---@param enable boolean|nil omit to flip
function M.toggle_todos(enable)
  return session.toggle_todos(enable)
end

--- Insert the latest TODO(human) items as comments in your buffers.
function M.insert_todos()
  session.insert_todos()
end

--- Remove TODO(human) marker comments again.
---@param all boolean|nil true sweeps the repo instead of the current buffer
function M.clear_todos(all)
  session.clear_todos(all)
end

return M
