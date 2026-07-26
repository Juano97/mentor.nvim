--- Choosing the model: at setup, at runtime, and what the transcript says
--- about which one answered.
local h = require("harness")

local dir = h.fixture()
h.enter(dir)
require("mentor").setup({})

local mentor = require("mentor")
local session = require("mentor.session")
local ui = require("mentor.ui")
local provider = require("mentor.provider")
local cfg = require("mentor.config").get()

local real_resolve = provider.resolve

------------------------------------------------------------------- defaults

h.eq("no model pinned by default", cfg.claude_cli.model, nil)
h.check("completion suggests the aliases",
  vim.tbl_contains(cfg.claude_cli.models, "opus"), vim.inspect(cfg.claude_cli.models))

-- Whichever backend is live here, :MentorModel must target that one's config.
local _, live = real_resolve(cfg)
h.check("resolve names a backend", live ~= nil)
h.eq("model() reports the live backend", select(2, mentor.model()), live)

-- The HTTP backend keeps its own model, and "default" is meaningless there
-- because the model goes in the request body.
cfg.provider = "openai_compat"
mentor.set_model("some-local-model")
h.eq("set_model targets the active backend", cfg.openai_compat.model, "some-local-model")
h.eq("...and leaves the other alone", cfg.claude_cli.model, nil)
mentor.set_model("default")
h.eq("'default' is refused where a model is required",
  cfg.openai_compat.model, "some-local-model")
cfg.provider = "claude_cli"

------------------------------------------------------------------- runtime set

h.eq("set returns what it set", mentor.set_model("opus"), "opus")
h.eq("stored on the backend config", cfg.claude_cli.model, "opus")
h.eq("reporting does not clear it", mentor.set_model(), "opus")
h.eq("whitespace is trimmed", mentor.set_model("  sonnet  "), "sonnet")
-- Anything the backend accepts must pass through untouched. The string below
-- is a placeholder on purpose: the CLI is the authority on what exists, and a
-- real id baked in here would only go stale.
h.eq("an exact id passes through", mentor.set_model("some-exact-model-id"),
  "some-exact-model-id")
h.eq("'default' unsets", mentor.set_model("default"), nil)

------------------------------------------------------------- reaches the backend

local get = h.stub_provider()
local function settle()
  vim.wait(2000, function()
    return not session.state.busy
  end)
end

mentor.set_model("opus")
session.ask("first")
settle()
h.eq("the request carries the model", get().cfg.model, "opus")

mentor.set_model("sonnet")
session.ask("second")
settle()
h.eq("a switch applies without resetting the conversation", get().cfg.model, "sonnet")
h.check("...and the session handle survives it", get().state == session.state.provider_state)

-------------------------------------------------------------------- transcript

local function transcript()
  return table.concat(vim.api.nvim_buf_get_lines(ui.state.buf, 0, -1, false), "\n")
end

local function count(text, needle)
  local n, from = 0, 1
  while true do
    local at = text:find(needle, from, true)
    if not at then
      return n
    end
    n, from = n + 1, at + 1
  end
end

h.eq("the first answer names its model", count(transcript(), "▍mentor — opus"), 1)
h.eq("a switch is marked", count(transcript(), "▍mentor — sonnet"), 1)

session.ask("third")
settle()
h.eq("an unchanged model is not repeated", count(transcript(), "▍mentor — sonnet"), 1)
h.eq("...the header is still there", count(transcript(), "▍mentor"), 3)

session.reset()
session.ask("after reset")
settle()
h.eq("a fresh conversation re-states the model",
  count(transcript(), "▍mentor — sonnet"), 1)

provider.resolve = real_resolve
h.cleanup(dir)
