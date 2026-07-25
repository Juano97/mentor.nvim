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

function M.toggle()
  session.toggle()
end

function M.stop()
  session.stop()
end

function M.reset()
  session.reset()
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

return M
