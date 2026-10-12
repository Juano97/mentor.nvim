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
  -- The input box's height once you have resized it by hand; nil means
  -- `window.input_height`. Kept across closing and reopening the panel, for
  -- the rest of the session.
  input_height = nil,
  layout = nil, -- the windows in the tab when the box was last checked
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
--- Put the input box back to its configured height, the transcript taking up
--- whatever the change leaves.
---
--- `winfixheight` is a preference, not a guarantee: when a window opens or
--- closes across the whole width — a terminal at the bottom, a quickfix list —
--- vim hands the rows it takes or frees to the bottom window of every column,
--- and in the panel's column that is the input box. Opening a terminal
--- squeezed it to one line and closing it again left it twenty lines tall, with
--- the transcript stuck at half the screen above it. The height it goes back
--- to is `input_height`, or the one you last gave it by hand — telling those
--- two kinds of resize apart is `sync_input_height`'s job.
---@param height integer
function M.keep_input_height(height)
  local iwin = M.state.input_win
  if not (valid_win(iwin) and valid_win(M.state.win)) then
    return
  end
  if vim.api.nvim_win_get_height(iwin) ~= height then
    pcall(vim.api.nvim_win_set_height, iwin, height)
  end
end

--- The border between the transcript and the input box, drawn as a handle.
---
--- That border can be dragged to resize the box, and nothing about a plain
--- separator says so. Which line it is depends on 'laststatus': with a global
--- statusline (3) it is the separator under the transcript, drawn with
--- `fillchars.horiz` and `WinSeparator`; otherwise it is the transcript's own
--- statusline. Both are dressed, window-locally, so the same panel reads the
--- same way under either setting and nothing outside it changes.
local GRIP = "━"
local GRIP_STL = "%!v:lua.require'mentor.ui'.grip_statusline()"
local GRIP_WHL = "WinSeparator:MentorGrip"

local function define_grip_hl()
  -- `default`, so a colorscheme or the user can restyle it.
  vim.api.nvim_set_hl(0, "MentorGrip", { link = "Special", default = true })
end

--- The transcript's statusline: the grip, unless that line is the global one.
---
--- Set as `%!` so it is decided per redraw. With 'laststatus' 3 the window's
--- own statusline is what the *global* one shows while the cursor is in the
--- transcript, and a row of handles there would replace the user's statusline,
--- so that case hands back the global format instead. A `%!` there would not
--- be re-evaluated inside this one, so it is rewrapped as `%{%...%}`.
---@return string
function M.grip_statusline()
  -- A window split off the panel copies this option along with the rest; the
  -- grip belongs to the transcript only.
  local drawing = vim.g.statusline_winid
  if vim.o.laststatus == 3 or (drawing and drawing ~= M.state.win) then
    local global = vim.go.statusline
    if global:sub(1, 2) == "%!" then
      return "%{%" .. global:sub(3) .. "%}"
    end
    return global
  end
  local width = valid_win(M.state.win) and vim.api.nvim_win_get_width(M.state.win) or 0
  local left = math.max(0, math.floor((width - 3) / 2))
  local right = math.max(0, width - 3 - left)
  return "%#MentorGrip#" .. GRIP:rep(left) .. " ⋯ " .. GRIP:rep(right)
end

---@param win integer
local function dress_grip(win)
  -- The effective value, so the user's other fill characters survive; only
  -- the ones below are ours. `stl` is left alone: under a global statusline it
  -- would fill the user's statusline whenever the cursor is in the panel.
  --
  -- The corner where the line meets the code window's border comes from this
  -- window's `vertright` (`vertleft` with the panel on the left). Left at its
  -- default it is a thin `├` in the grip colour on a dark border: a stray
  -- tick, then a gap before the line starts. The grip itself runs the line
  -- flush into the border instead.
  local ours = { "horiz", "vertright", "vertleft" }
  local kept = {}
  local current = vim.wo[win].fillchars
  if current == "" then
    current = vim.go.fillchars -- no local value of its own yet
  end
  for item in current:gmatch("[^,]+") do
    if not vim.tbl_contains(ours, item:match("^[^:]+")) then
      kept[#kept + 1] = item
    end
  end
  for _, name in ipairs(ours) do
    kept[#kept + 1] = name .. ":" .. GRIP
  end
  vim.wo[win].fillchars = table.concat(kept, ",")
  vim.wo[win].statusline = GRIP_STL
end

--- Take the grip off a window that only has it by inheritance.
---
--- `:split` copies window-local options into the new window, so anything
--- opened from inside the panel — a terminal, a `:split` of your own — would
--- arrive wearing the transcript's border, and a window that is not the panel
--- has no business with it. Only our own values are removed.
---@param win integer
function M.strip_grip(win)
  if not valid_win(win) then
    return
  end
  local wo = vim.wo[win]
  if wo.statusline == GRIP_STL then
    wo.statusline = ""
  end
  if wo.fillchars:find("horiz:" .. GRIP, 1, true) then
    wo.fillchars = ""
  end
  local whl = vim.tbl_filter(function(item)
    return item ~= GRIP_WHL
  end, vim.split(wo.winhighlight, ",", { trimempty = true }))
  wo.winhighlight = table.concat(whl, ",")
end

--- The ordinary windows in this tab, as a string that changes exactly when
--- one opens or closes.
---@return string
local function layout_key()
  local wins = vim.tbl_filter(function(w)
    return vim.api.nvim_win_get_config(w).relative == ""
  end, vim.api.nvim_tabpage_list_wins(0))
  table.sort(wins)
  return table.concat(wins, ",")
end

--- After a resize: put the box back, or learn that you meant it.
---
--- The resize event says only that the box changed height, never why, and a
--- border you dragged looks exactly like a terminal that opened. What differs
--- is the window list. A terminal, a quickfix list or a split opening or
--- closing changes which windows exist; `<C-w>+`, `:resize` and a mouse drag
--- change sizes and nothing else. So with the same windows as last time, the
--- new height is yours and becomes the one kept. With different windows it is
--- a side effect, and the box goes back. A resize of nvim itself is always a
--- side effect.
---@param default integer `window.input_height`
---@param vim_resized boolean|nil
function M.sync_input_height(default, vim_resized)
  local iwin = M.state.input_win
  if not (valid_win(iwin) and valid_win(M.state.win)) then
    return
  end
  local key = layout_key()
  local want = M.state.input_height or default
  local now = vim.api.nvim_win_get_height(iwin)
  if not vim_resized and key == M.state.layout and now ~= want then
    M.state.input_height = now
  else
    M.keep_input_height(want)
  end
  M.state.layout = key
end

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
  if not require("mentor.session").submit(text) then
    return
  end
  vim.api.nvim_buf_set_lines(M.state.input_buf, 0, -1, false, { "" })
  if vim.fn.mode():sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end
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

-- The user's own `completeopt`, held while the command menu is up.
local saved_completeopt = nil

--- Show the menu without writing into the buffer.
---
--- Vim's default `completeopt` inserts the first match as soon as the popup
--- opens, so a bare `/` would become `/help` and the next keystroke would land
--- on the end of it. `noinsert` leaves the text alone until you pick one, and
--- `menuone` keeps the menu up when your typing has narrowed it to a single
--- command. Neither is ours to set permanently: 'completeopt' is global until
--- nvim 0.11 and this plugin supports 0.10, so it is borrowed and handed back.
local function borrow_completeopt()
  if saved_completeopt == nil then
    saved_completeopt = vim.o.completeopt
  end
  vim.o.completeopt = "menu,menuone,noinsert"
end

local function return_completeopt()
  if saved_completeopt ~= nil then
    vim.o.completeopt = saved_completeopt
    saved_completeopt = nil
  end
end

--- `completefunc` for the input box: the panel commands, offered while the
--- line is nothing but a leading slash-word.
---
--- The guard is the same one `session.submit` applies, and for the same
--- reason: `/usr/bin/env, what is that?` is a question about a path. A menu
--- that popped up there would be answering a question nobody asked, so
--- anything past the first word returns -1 and completion falls through to
--- whatever the user has wired up.
---
--- Called by Vim with (1, "") to find the start column, then (0, base) for the
--- matches.
---@param findstart integer 1 = report where the word begins
---@param base string what has been typed so far
---@return integer|table[] column when findstart, else the candidate list
function M.complete_command(findstart, base)
  local line = vim.api.nvim_get_current_line()

  if findstart == 1 then
    -- Byte offset of the `/`, or -1 to leave completion to someone else.
    return line:match("^/[%w_-]*$") and 0 or -1
  end

  local items = {}
  for _, item in ipairs(require("mentor.session").commands()) do
    if vim.startswith(item.word, base) then
      items[#items + 1] = item
    end
  end
  return items
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

  -- `completefunc` rather than `omnifunc`: an LSP setup has usually claimed
  -- omni already, and this buffer is not a file anyone's server knows about.
  if require("mentor.config").get().window.complete_commands ~= false then
    vim.bo[buf].completefunc = "v:lua.require'mentor.ui'.complete_command"

    -- Typing the slash opens the menu, but only as the first character of the
    -- line — the one place a slash can begin a command. Everywhere else it is
    -- punctuation in a question and stays a plain keystroke.
    vim.keymap.set("i", "/", function()
      if vim.fn.col(".") ~= 1 then
        return "/"
      end
      borrow_completeopt()
      return "/<C-x><C-u>"
    end, vim.tbl_extend("force", opts, { expr = true, desc = "Mentor: complete command" }))

    -- Whatever the user's `completeopt` was, it comes back the moment the menu
    -- closes — CompleteDone fires on accept and on abort alike. InsertLeave is
    -- the belt: <C-c> out of a menu leaves no CompleteDone behind.
    vim.api.nvim_create_autocmd({ "CompleteDone", "InsertLeave" }, {
      group = vim.api.nvim_create_augroup("mentor_complete", { clear = true }),
      buffer = buf,
      callback = return_completeopt,
      desc = "Mentor: restore completeopt",
    })
  end

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
  vim.api.nvim_win_set_height(iwin, M.state.input_height or cfg.input_height or 5)

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

  -- The panel's own windows were split from yours too, and may have come
  -- with a grip inherited from an earlier panel: start them clean.
  M.strip_grip(win)
  M.strip_grip(iwin)
  if cfg.grip ~= false then
    define_grip_hl()
    dress_grip(win)
    -- Both windows, though only the transcript has a border under it: with the
    -- panel on the left, the vertical border beside it belongs to these two,
    -- and half of it coloured would look like a mistake.
    for _, w in ipairs({ win, iwin }) do
      local whl = vim.wo[w].winhighlight
      vim.wo[w].winhighlight = (whl ~= "" and whl .. "," or "") .. GRIP_WHL
    end
  end

  M.state.win = win
  M.state.input_win = iwin

  local group = vim.api.nvim_create_augroup("mentor_panel", { clear = true })

  -- `:colorscheme` clears every group it does not define, MentorGrip included.
  if cfg.grip ~= false then
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_grip_hl })
    -- WinNew runs in the new window, which is the one that may have inherited.
    vim.api.nvim_create_autocmd("WinNew", {
      group = group,
      callback = function()
        local new = vim.api.nvim_get_current_win()
        if new ~= M.state.win and new ~= M.state.input_win then
          M.strip_grip(new)
        end
      end,
    })
  end

  -- Every resize, not only ones that name a panel window: the box is resized
  -- as a side effect of some other window opening or closing. Scheduled for
  -- the reason the scroll clamp is — whatever triggered the resize may still
  -- be laying windows out when the event fires.
  local height = cfg.input_height or 5
  local resize_queued = false
  local vim_resized = false
  M.state.layout = layout_key()
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function(args)
      -- Several events can land before the scheduled check runs; if any of
      -- them was nvim itself resizing, the check has to know.
      vim_resized = vim_resized or args.event == "VimResized"
      if resize_queued then
        return
      end
      resize_queued = true
      vim.schedule(function()
        resize_queued = false
        local whole = vim_resized
        vim_resized = false
        M.sync_input_height(height, whole)
      end)
    end,
  })

  -- Only the transcript. The input box is one you type into, so its view has to
  -- follow the cursor, and a clamp would fight that.
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

--- Put the transcript on its last line.
---
--- Unconditional, unlike `follow()`: for a conversation you just asked to load,
--- the end is the part you want, and there is no reader to interrupt. Needs the
--- panel to be open — a buffer with no window has no view to move.
function M.scroll_to_end()
  if not M.win_valid() or not valid_buf(M.state.buf) then
    return
  end
  local n = vim.api.nvim_buf_line_count(M.state.buf)
  pcall(vim.api.nvim_win_set_cursor, M.state.win, { n, 0 })
end

-- Scroll to the bottom, but never steal the cursor if the user is reading.
local function follow()
  if vim.api.nvim_get_current_win() == M.state.win then
    return
  end
  M.scroll_to_end()
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

--- The transcript as it stands, for saving it.
---@return string[]
function M.lines()
  return vim.api.nvim_buf_get_lines(M.ensure_buf(), 0, -1, false)
end

--- Put a whole transcript back (resuming a saved conversation).
---@param lines string[]
function M.replace(lines)
  local buf = M.ensure_buf()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  follow()
end

return M
