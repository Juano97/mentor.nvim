local M = {}

---@class MentorConfig
M.defaults = {
  -- "auto" picks claude_cli when the binary exists, else openai_compat.
  provider = "auto",

  window = {
    width = 0.20, -- fraction of `columns`; clamped to min_width
    min_width = 34,
    position = "right", -- "right" | "left"
    wrap = true,
    input_height = 5, -- lines in the input box below the transcript
    -- Toggling the panel open puts the cursor in the input box and starts
    -- insert. Set false to have :Mentor only reveal the panel.
    focus_on_open = true,
    -- The transcript stops at its last line instead of scrolling on into the
    -- empty rows below it. Set true for stock Vim scrolling.
    scroll_past_end = false,
  },

  ---------------------------------------------------------------------------
  -- Backend 1: the Claude Code CLI in headless mode.
  -- Runs on whatever auth the user already has, so a Pro/Max subscription
  -- means no per-query API cost.
  ---------------------------------------------------------------------------
  claude_cli = {
    cmd = "claude",
    -- nil = whatever the CLI is set to. Anything `--model` accepts works: an
    -- alias ("opus", "sonnet") or a full model id.
    model = nil,
    -- Suggestions for :MentorModel's completion, nothing more — any string is
    -- accepted. Deliberately just the aliases: pinning version numbers in here
    -- would only rot, and `claude --model` is the authority on what exists.
    models = { "default", "opus", "sonnet", "haiku" },

    -- THE HARD GUARDRAIL. These are not suggestions to the model; the tools
    -- simply are not present in the session, so there is nothing to refuse.
    -- Read/Grep/Glob let it look around the project to answer well.
    tools = { "Read", "Grep", "Glob" },
    disallowed_tools = {
      "Edit", "Write", "NotebookEdit", "Bash",
      "Task", "WebFetch", "WebSearch", "TodoWrite",
    },

    -- Without these, ambient MCP servers and user settings leak extra tools
    -- into the session and quietly widen the sandbox.
    strict_mcp_config = true,
    setting_sources = "", -- "" loads none; or e.g. "project"

    -- "append" keeps Claude Code's tool-use instructions and adds the tutor
    -- persona. "replace" drops them entirely (cheaper, less capable at
    -- navigating a codebase).
    system_prompt_mode = "append",

    stream = true,
    extra_args = {},
  },

  ---------------------------------------------------------------------------
  -- Backend 2: any OpenAI-compatible endpoint.
  -- Covers Gemini (free tier), Groq, OpenRouter, and local Ollama, and is the
  -- seam for "bring your own service" later.
  ---------------------------------------------------------------------------
  openai_compat = {
    base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
    model = "gemini-2.0-flash",
    -- :MentorModel completion. Empty by default: what an endpoint serves is
    -- entirely up to the endpoint, so only you can fill this in usefully.
    models = {},
    api_key_env = "GEMINI_API_KEY",
    max_tokens = 2048,
    stream = true,
    extra_headers = {},
  },

  ---------------------------------------------------------------------------
  -- Saved conversations. Each turn writes the transcript and the backend's
  -- handle on it to stdpath("state"), per repo, so :MentorResume can pick a
  -- conversation up in a later nvim. This is the one place the plugin puts the
  -- model's prose on disk without you pressing a key; save = false keeps
  -- everything in memory and loses it with the process.
  ---------------------------------------------------------------------------
  history = {
    save = true,
    max = 20, -- conversations kept per repo; the oldest are pruned first
    dir = nil, -- default: stdpath("state") .. "/mentor"
  },

  context = {
    -- Truncate large diffs so one refactor doesn't blow the request up.
    max_diff_lines = 600,
    -- "worktree" = unstaged changes, "staged" = index, "head" = both.
    diff_target = "worktree",
    -- Cap on a visual selection sent with a question.
    max_selection_lines = 200,

    -- Project brief: a file at the repo root saying what this project is, sent
    -- once at the start of a conversation so the mentor is not inferring the
    -- whole codebase from one diff. Set false to never look for one.
    project_brief = true,
    -- Searched at the repo root, first hit wins. The first entry doubles as
    -- what :MentorInit drafts; the rest are read but never written.
    project_brief_files = { "MENTOR.md", "CLAUDE.md", "AGENTS.md" },
    max_brief_lines = 200,
  },

  ---------------------------------------------------------------------------
  -- Learning mode: the mentor ends each answer with concrete work handed back
  -- to you, and you can drop those as comment markers into your own buffers.
  -- The model still writes nothing — the plugin inserts the comment.
  ---------------------------------------------------------------------------
  learning = {
    todos = true, -- ask for a TODO section; toggle at runtime with :MentorTodos
    marker = "TODO(human)",
  },

  -- Set any entry to false to skip that mapping.
  keymaps = {
    toggle = "<leader>mm",
    ask = "<leader>ma",
    review = "<leader>mr",
    stop = "<leader>ms",
    reset = "<leader>mx",
    todos = "<leader>mt", -- toggle learning-mode TODOs on/off
    todo_insert = "<leader>mi", -- insert the latest TODOs as comments
  },
}

---@type MentorConfig
M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

function M.get()
  return M.options
end

return M
