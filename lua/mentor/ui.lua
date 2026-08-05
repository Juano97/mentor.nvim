--- The side panel: a read-only transcript on top, a writable input box below.
local M = {}

M.state = {
  buf = nil, -- transcript (read-only)
  win = nil,
  input_buf = nil, -- where you type
  input_win = nil,
  status = "idle", -- "idle" | "busy"
  pending = nil, -- label for an attached selection
  timer = nil,
  frame = 1,
}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function valid_buf(b)
  return b and vim.api.nvim_buf_is_valid(b)
end

local function valid_win(w)
  return w and vim.api.nvim_win_is_valid(w)
end

function M.win_valid()
  return valid_win(M.state.win)
end

function M.input_win_valid()
  return valid_win(M.state.input_win)
end

--------------------------------------------------------------- status / winbar

--- Redraw the input box's winbar from state. Everything the user needs to know
--- about what the panel is doing lives on this one line.
function M.render_winbar()
  if not valid_win(M.state.input_win) then
    return
  end
  local parts = {}
  if M.state.status == "busy" then
    parts[#parts + 1] = SPINNER[M.state.frame] .. " thinking… :MentorStop"
  else
    parts[#parts + 1] = "ask — <CR> send"
  end
  if M.state.pending then
    parts[#parts + 1] = "[" .. M.state.pending:gsub("%%", "%%%%") .. "]"
  end
  vim.wo[M.state.input_win].winbar = "%#Comment#" .. table.concat(parts, "  ") .. "%*"
end

local function stop_spinner()
  if M.state.timer then
    pcall(function()
      M.state.timer:stop()
      M.state.timer:close()
    end)
    M.state.timer = nil
  end
end

local function start_spinner()
  stop_spinner()
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  M.state.timer = timer
  timer:start(0, 100, vim.schedule_wrap(function()
    if M.state.status ~= "busy" then
      stop_spinner()
      return
    end
    M.state.frame = (M.state.frame % #SPINNER) + 1
    M.render_winbar()
  end))
end

---@param status "idle"|"busy"
function M.set_status(status)
  M.state.status = status
  if status == "busy" then
    start_spinner()
  else
    stop_spinner()
  end
  M.render_winbar()
end

--- Label for a code selection attached to the next message (nil clears it).
---@param label string|nil
function M.set_pending(label)
  M.state.pending = label
  M.render_winbar()
end

------------------------------------------------------------------------ scroll

--- Stop the transcript scrolling off into the empty rows past its last line.
---
--- Vim will happily scroll until the final line sits at the *top* of the
--- window, which in a panel this narrow means a screenful of `~` and the
--- conversation gone. The end of the transcript is the end of the thing being
--- read, so it stays on the bottom row.
---
--- Hooked to `WinScrolled` rather than to keys: `<C-e>`, `<C-f>`, the mouse
--- wheel and whatever the user has bound themselves all arrive here, and
--- remapping them one by one would miss the rest.
local function clamp_scroll()
  local win = M.state.win
  if not valid_win(win) or not valid_buf(M.state.buf) then
    return
  end
  vim.api.nvim_win_call(win, function()
    local height = vim.api.nvim_win_get_height(win)
    local view = vim.fn.winsaveview()
    local top = view.topline

    -- Screen rows, not buffer lines: `wrap` is on by default in a column this
    -- narrow, so one line is often several rows and only the window knows how
    -- many. `max_height` stops the count as soon as the answer is settled.
    local function rows_below(t)
      return vim.api.nvim_win_text_height(win, { start_row = t - 1, max_height = height }).all
    end

    -- Walking up beats solving for the topline: it lands on 1 by itself when
    -- the whole transcript is shorter than the window.
    while top > 1 and rows_below(top) < height do
      top = top - 1
    end

    if top ~= view.topline then
      view.topline = top
      vim.fn.winrestview(view)
    end
  end)
end

--- Correct on the next tick, not inside the `WinScrolled` callback itself: a
--- `<C-f>` still has scrolling of its own to finish when the event fires, and
--- it overwrites anything set from in there. One tick later the view has
--- settled and the correction sticks.
---
--- The flag collapses a burst of events into a single correction — a mouse
--- wheel emits a stream of them.
local clamp_queued = false
local function clamp_scroll_soon()
  if clamp_queued then
    return
  end
  clamp_queued = true
  vim.schedule(function()
    clamp_queued = false
    clamp_scroll()
  end)
end

--------------------------------------------------------------------------- ui

--- Send whatever is in the input box.
---
--- `session.submit` decides whether that is a question or a panel command, and
--- says whether it took it. A no keeps the text where you typed it — a mistyped
--- `/resume` is worth fixing, not retyping.
function M.submit()
  if not valid_buf(M.state.input_buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(M.state.input_buf, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    return
  end
  vim.api.nvim_buf_set_lines(M.state.input_buf, 0, -1, false, { "" })
  if vim.fn.mode():sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end
  require("mentor.session").ask(text)
end

---@return integer bufnr
function M.ensure_buf()
  if valid_buf(M.state.buf) then
    return M.state.buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "mentor://chat")

  local opts = { buffer = buf, nowait = true, silent = true }

  vim.keymap.set("n", "q", function() M.close() end,
    vim.tbl_extend("force", opts, { desc = "Mentor: close panel" }))

  -- On a TODO(human) line, drop the marker into the file it points at.
  vim.keymap.set("n", "<CR>", function()
    require("mentor.session").insert_todos()
  end, vim.tbl_extend("force", opts, { desc = "Mentor: insert TODO marker" }))

  -- Typing in the transcript jumps to the input box instead of beeping.
  for _, key in ipairs({ "i", "a", "o", "A", "I" }) do
    vim.keymap.set("n", key, function() M.focus_input() end,
      vim.tbl_extend("force", opts, { desc = "Mentor: focus input" }))
  end

  M.state.buf = buf
  return buf
end

---@return integer bufnr
function M.ensure_input_buf()
  if valid_buf(M.state.input_buf) then
    return M.state.input_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, "mentor://input")

  local opts = { buffer = buf, nowait = true, silent = true }

  -- <CR> sends from normal mode; insert mode keeps it as a newline so you can
  -- write more than one line. <C-s> sends without leaving insert.
  vim.keymap.set("n", "<CR>", M.submit,
    vim.tbl_extend("force", opts, { desc = "Mentor: send" }))
  vim.keymap.set("i", "<C-s>", M.submit,
    vim.tbl_extend("force", opts, { desc = "Mentor: send" }))
  vim.keymap.set("n", "<C-s>", M.submit,
    vim.tbl_extend("force", opts, { desc = "Mentor: send" }))

  vim.keymap.set("n", "q", function() M.close() end,
    vim.tbl_extend("force", opts, { desc = "Mentor: close panel" }))
  vim.keymap.set("n", "<Esc>", function()
    if valid_win(M.state.win) then
      vim.api.nvim_set_current_win(M.state.win)
    end
  end, vim.tbl_extend("force", opts, { desc = "Mentor: back to transcript" }))

  M.state.input_buf = buf
  return buf
end

---@param cfg table window config
function M.open(cfg)
  if M.win_valid() then
    return M.state.win
  end

  local transcript = M.ensure_buf()
  local input = M.ensure_input_buf()
  local prev = vim.api.nvim_get_current_win()

  -- One column on the side...
  vim.cmd(cfg.position == "left" and "topleft vsplit" or "botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, transcript)
  vim.api.nvim_win_set_width(win, math.max(cfg.min_width, math.floor(vim.o.columns * cfg.width)))

  -- ...split horizontally so the input box sits underneath, same column.
  vim.cmd("belowright split")
  local iwin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(iwin, input)
  vim.api.nvim_win_set_height(iwin, cfg.input_height or 5)

  for _, w in ipairs({ win, iwin }) do
    local wo = vim.wo[w]
    wo.wrap = cfg.wrap
    wo.linebreak = true
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"
    wo.spell = false
    wo.winfixwidth = true
  end
  vim.wo[win].cursorline = false
  vim.wo[iwin].winfixheight = true

  M.state.win = win
  M.state.input_win = iwin

  -- Only the transcript. The input box is one you type into, so its view has to
  -- follow the cursor, and a clamp would fight that.
  local group = vim.api.nvim_create_augroup("mentor_panel", { clear = true })
  if not cfg.scroll_past_end then
    vim.api.nvim_create_autocmd("WinScrolled", {
      group = group,
      pattern = tostring(win),
      callback = clamp_scroll_soon,
    })
  end

  M.render_winbar()

  if valid_win(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  return win
end

function M.close()
  stop_spinner()
  pcall(vim.api.nvim_del_augroup_by_name, "mentor_panel")
  for _, key in ipairs({ "input_win", "win" }) do
    if valid_win(M.state[key]) then
      pcall(vim.api.nvim_win_close, M.state[key], true)
    end
    M.state[key] = nil
  end
end

function M.toggle(cfg)
  if M.win_valid() then
    M.close()
  else
    M.open(cfg)
    -- Opening the panel by hand means you want to ask something, so land in the
    -- input box ready to type. `open` itself stays where it was on purpose: the
    -- streaming path opens the panel while you are still in your code.
    if cfg.focus_on_open ~= false then
      M.focus_input(cfg)
    end
  end
end

--- Open the panel if needed, put the cursor in the input box, start insert.
---@param cfg table|nil window config; fetched from config when omitted
function M.focus_input(cfg)
  cfg = cfg or require("mentor.config").get().window
  if not M.win_valid() then
    M.open(cfg)
  end
  if M.input_win_valid() then
    vim.api.nvim_set_current_win(M.state.input_win)
    vim.cmd("startinsert!")
  end
end

----------------------------------------------------------------- transcript io

-- Scroll to the bottom, but never steal the cursor if the user is reading.
local function follow()
  if not M.win_valid() or not valid_buf(M.state.buf) then
    return
  end
  if vim.api.nvim_get_current_win() == M.state.win then
    return
  end
  local n = vim.api.nvim_buf_line_count(M.state.buf)
  pcall(vim.api.nvim_win_set_cursor, M.state.win, { n, 0 })
end

--- Append text that may arrive mid-line (streaming deltas).
--- Must run on the main loop; callers schedule.
---@param text string
function M.append(text)
  if text == nil or text == "" then
    return
  end
  local buf = M.ensure_buf()
  local lines = vim.split(text, "\n", { plain = true })

  vim.bo[buf].modifiable = true
  local last_idx = vim.api.nvim_buf_line_count(buf)
  local last_line = vim.api.nvim_buf_get_lines(buf, last_idx - 1, last_idx, false)[1] or ""
  lines[1] = last_line .. lines[1]
  vim.api.nvim_buf_set_lines(buf, last_idx - 1, last_idx, false, lines)
  vim.bo[buf].modifiable = false

  follow()
end

---@param lines string[]
function M.append_lines(lines)
  M.append(table.concat(lines, "\n") .. "\n")
end

--- Blank line separator that never stacks up.
function M.ensure_blank_line()
  local buf = M.ensure_buf()
  local n = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
  if last ~= "" then
    M.append("\n")
  end
end

---@param role "user"|"mentor"|"system"
---@param text string|nil
function M.header(role, text)
  local icon = ({ user = "▍you", mentor = "▍mentor", system = "▍" })[role] or "▍"
  M.ensure_blank_line()
  M.append(("%s%s\n"):format(icon, text and (" — " .. text) or ""))
end

function M.clear()
  local buf = M.ensure_buf()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modifiable = false
end

return M
