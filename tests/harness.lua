--- Minimal assertion + fixture harness. One instance per nvim process; specs
--- get the same table via require("harness").
local M = { passed = 0, failed = 0 }

function M.out(s)
  io.stdout:write(tostring(s) .. "\n")
end

---@param label string
---@param ok boolean
---@param extra any shown only on failure
function M.check(label, ok, extra)
  if ok then
    M.passed = M.passed + 1
    M.out("  ok    " .. label)
  else
    M.failed = M.failed + 1
    M.out("  FAIL  " .. label .. (extra ~= nil and ("  -- " .. tostring(extra)) or ""))
  end
end

---@param label string
function M.eq(label, got, want)
  M.check(label, got == want, ("got %s, want %s"):format(vim.inspect(got), vim.inspect(want)))
end

function M.skip(reason)
  M.out("  skip  " .. reason)
end

---------------------------------------------------------------------- fixture

local ORIGINAL = {
  "def total(items):",
  "    result = 0",
  "    for item in items:",
  "        result += item.price",
  "    return result",
}

-- The working-tree version: introduces `qty` and an unvalidated `discount`, so
-- there is always a real diff for review specs to chew on.
local CHANGED = {
  "def total(items, discount=0):",
  "    result = 0",
  "    for item in items:",
  "        result += item.price * item.qty",
  "    if discount:",
  "        result = result - result * discount",
  "    return round(result, 2)",
}

--- A throwaway git repo. Returns its path.
---@return string dir
function M.fixture()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  local function git(...)
    local args = { "git", "-C", dir, ... }
    local res = vim.system(args, { text = true }):wait(10000)
    assert(res.code == 0, "fixture git failed: " .. table.concat(args, " ") .. "\n" .. (res.stderr or ""))
  end

  vim.fn.writefile(ORIGINAL, dir .. "/cart.py")
  git("init", "-q")
  git("config", "user.email", "test@example.invalid")
  git("config", "user.name", "mentor tests")
  git("add", "-A")
  git("commit", "-qm", "init")

  vim.fn.writefile(CHANGED, dir .. "/cart.py")
  -- Extra languages for the commentstring spec. Never opened by the specs, so
  -- they exercise the bufadd()/bufload() path where filetype is unset.
  vim.fn.writefile({ "local M = {}", "return M" }, dir .. "/mod.lua")
  vim.fn.writefile({ "export const a = 1;" }, dir .. "/app.js")
  vim.fn.writefile({ "body { color: red; }" }, dir .. "/style.css")

  return dir
end

--- Enter the fixture: cd into it and open the Python file.
---@param dir string
function M.enter(dir)
  vim.cmd("cd " .. vim.fn.fnameescape(dir))
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/cart.py"))
end

---@param dir string|nil
function M.cleanup(dir)
  if dir and #dir > 5 then
    vim.fn.delete(dir, "rf")
  end
end

--- Replace the provider with one that records the request instead of calling
--- out. Returns a getter for whatever was captured.
---@return function get_captured
function M.stub_provider()
  local captured
  require("mentor.provider").resolve = function()
    return {
      display_name = "stub",
      available = function() return true end,
      chat = function(o)
        captured = o
        vim.schedule(function()
          o.on_delta("ok")
          o.on_done()
        end)
        return { kill = function() end }
      end,
    }, "claude_cli", nil
  end
  return function() return captured end
end

---@return integer exit_code
function M.finish()
  M.out(("\n  %d passed, %d failed"):format(M.passed, M.failed))
  return M.failed == 0 and 0 or 1
end

return M
