if vim.g.loaded_mentor then
  return
end
vim.g.loaded_mentor = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("[mentor] requires Neovim 0.10+ (vim.system)", vim.log.levels.ERROR)
  return
end

local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

cmd("Mentor", function()
  require("mentor").toggle()
end, { desc = "Toggle the mentor panel" })

cmd("MentorAsk", function(a)
  local mentor = require("mentor")
  local question = a.args ~= "" and a.args or nil
  if a.range > 0 then
    -- :'<,'>MentorAsk  /  :10,20MentorAsk why is this slow?
    mentor.ask_range(a.line1, a.line2, question)
  else
    mentor.ask(question)
  end
end, { nargs = "*", range = true, desc = "Ask the mentor a question" })

cmd("MentorReview", function()
  require("mentor").review()
end, { desc = "Review the most recent changes" })

cmd("MentorInit", function()
  require("mentor").init()
end, { desc = "Draft a project brief for this repo (you review and save it)" })

cmd("MentorRevision", function()
  require("mentor").revise()
end, { desc = "Draft a revision of the project brief beside it (you merge it)" })

cmd("MentorModel", function(a)
  require("mentor").set_model(a.args ~= "" and a.args or nil)
end, {
  nargs = "?",
  complete = function()
    return require("mentor").models()
  end,
  desc = "Show or set the model the active backend uses",
})

cmd("MentorStop", function()
  require("mentor").stop()
end, { desc = "Cancel the answer in flight" })

cmd("MentorReset", function()
  require("mentor").reset()
end, { desc = "Clear the conversation and the panel" })

cmd("MentorResume", function(a)
  require("mentor").resume(a.args ~= "" and a.args or nil)
end, {
  nargs = "?",
  -- The titles are prose and would not survive being command-line arguments,
  -- so the completion is positions: 1 is the most recent. No argument picks.
  complete = function()
    local n = #require("mentor").saved()
    return vim.tbl_map(tostring, vim.fn.range(1, math.min(n, 9)))
  end,
  desc = "Resume a saved conversation for this repo",
})

cmd("MentorTodos", function(a)
  local arg = a.args
  local enable = nil
  if arg == "on" then
    enable = true
  elseif arg == "off" then
    enable = false
  end
  require("mentor").toggle_todos(enable)
end, {
  nargs = "?",
  complete = function() return { "on", "off" } end,
  desc = "Toggle learning-mode TODO(human) items",
})

cmd("MentorTodoInsert", function()
  require("mentor").insert_todos()
end, { desc = "Insert the latest TODO(human) items as comments" })

cmd("MentorTodoClear", function(a)
  require("mentor").clear_todos(a.bang)
end, { bang = true, desc = "Remove TODO(human) comments here, or repo-wide with !" })
