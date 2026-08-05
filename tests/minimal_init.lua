--- Bootstrap for the test suite. Run one spec per nvim process:
---     MENTOR_SPEC=tests/foo_spec.lua nvim --headless -u tests/minimal_init.lua
--- Usually you want `make test` instead.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.resolve(this), ":p:h:h")

-- Prepend before startup finishes so plugin/mentor.lua is sourced normally.
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

vim.g.mapleader = " " -- deterministic: bare nvim would default to "\"
vim.g.maplocalleader = " "
vim.opt.swapfile = false
vim.opt.shada = ""
vim.opt.more = false

-- Every answered question saves a conversation. Point that at nvim's own temp
-- directory, which goes away with the process, so a test run never leaves
-- anything in the real stdpath("state").
require("mentor.config").defaults.history.dir = vim.fn.tempname()

vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function()
  local h = require("harness")
  local spec = vim.env.MENTOR_SPEC

  if not spec or spec == "" then
    h.out("MENTOR_SPEC is not set")
    vim.cmd("cq")
    return
  end

  local ok, err = pcall(dofile, spec)
  if not ok then
    h.failed = h.failed + 1
    h.out("  ERROR " .. tostring(err))
  end

  local code = h.finish()
  vim.cmd(code == 0 and "qa!" or "cq")
end })
