# mentor.nvim

A read-only AI tutor in a side panel. It answers questions about your project and
reviews your latest changes — and it cannot edit files, run commands, or install
anything, by construction.

Built for learning: the point is that you write the code.

## Why it can't touch your files

Two separate guarantees, deliberately not conflated:

**Hard guarantee — capability.** With the Claude CLI backend the session is
started with `--tools "Read,Grep,Glob"`, `--disallowedTools "Edit,Write,Bash,…"`,
`--strict-mcp-config` and `--setting-sources ""`. The write tools are not present
in the session, so there is nothing for the model to decide about. The HTTP
backend has no tools at all. Never enforce this with prompt wording.

**Soft guarantee — pedagogy.** A tutor system prompt (`lua/mentor/prompts.lua`)
stops it handing over finished implementations. This one *is* wording, so it is
the part that needs tuning; treat it as the file you iterate on.

## Requirements

- Neovim 0.10+ (uses `vim.system`)
- `git` for `:MentorReview`
- One backend:
  - **`claude_cli`** (default) — the `claude` binary, logged in. Runs on your
    existing subscription, so there is no per-query cost.
  - **`openai_compat`** — `curl` plus an API key. Points at Gemini's
    OpenAI-compatible endpoint out of the box; also works with Groq, OpenRouter
    and local Ollama.

## Install

lazy.nvim:

```lua
{
  dir = "~/Work/Personal/code-learning-ai-pluggin", -- or a git URL once published
  opts = {},
}
```

Then `:checkhealth mentor` to confirm the backend and the sandbox settings.

## Use

| Command | Default map | What it does |
|---|---|---|
| `:Mentor` | `<leader>mm` | Toggle the panel (right split, ~20% wide) |
| `:MentorAsk [text]` | `<leader>ma` | Ask a question; prompts if you give no text |
| `:MentorReview` | `<leader>mr` | Review your most recent changes |
| `:MentorStop` | `<leader>ms` | Cancel the answer in flight |
| `:MentorReset` | `<leader>mx` | Drop the conversation and clear the panel |
| `:MentorTodos [on\|off]` | `<leader>mt` | Toggle learning-mode TODOs |
| `:MentorTodoInsert` | `<leader>mi` | Insert the latest TODOs as comments |

### The panel

The panel is one column split into a read-only transcript on top and a writable
input box underneath:

```
┌──────────────────────┐
│ ▍you                 │
│ why is this wrong?   │  transcript — read-only, streams the answer
│ ▍mentor              │
│ Because …            │
├──────────────────────┤
│ ask — <CR> send      │  input box — type here
│ how do I test it?_   │
└──────────────────────┘
```

The input box's winbar is the status line: `ask — <CR> send` when idle, a
spinner and `thinking… :MentorStop` while a reply streams, plus `[cart.py:4-9]`
when a selection is attached.

| Key | Where | Does |
|---|---|---|
| `<leader>ma` | normal | Open the panel and start typing |
| `<leader>ma` | **visual** | Attach the selected lines, then type your question |
| `<CR>` | input, normal mode | Send |
| `<C-s>` | input, insert mode | Send without leaving insert |
| `<CR>` | input, insert mode | Newline — questions can be multi-line |
| `<Esc>` | input | Back to the transcript |
| `i` `a` `o` | transcript | Jump to the input box |
| `<CR>` | transcript, on a TODO line | Insert that marker |
| `q` | either | Close the panel |

Questions carry the file and line you were last working in — not the panel, even
though that is where the cursor is when you hit send. Reviews carry a `git diff`.

### Asking about specific lines

Select lines and press `<leader>ma`, or use a range on the command:

```vim
:'<,'>MentorAsk                      " attach the selection, then type
:10,20MentorAsk why is this slow?    " attach lines 10-20 and send at once
```

The selection is attached to the **next** message only, then cleared — the
winbar shows what is attached so you always know. It is sent as a fenced block
tagged with the file's language, capped at `context.max_selection_lines`.

`:MentorReview` uses unstaged changes by default, falls back to the last commit
when the tree is clean, and truncates past `context.max_diff_lines`.

## Learning mode (`TODO(human)`)

On by default. Every answer ends with the work handed back to you:

```
## TODO(human)
- `cart.py:5` — decide what should happen when `discount` is outside [0, 1):
  clamp, raise, or document that callers must validate.
- `cart.py:4` — confirm every caller of `total()` builds items with a `.qty`
  attribute now; update or grep for call sites if not.
```

Press `<CR>` on one of those lines in the panel to drop it into the file it
points at, or `:MentorTodoInsert` to place the whole latest batch:

```python
def total(items, discount=0):
    result = 0
    for item in items:
        # TODO(human): confirm every caller of total() builds items with a .qty attribute now; ...
        result += item.price * item.qty
    # TODO(human): decide what should happen when discount is outside [0, 1): ...
    if discount:
```

**The model does not write these.** It emits a path, a line and a sentence; Lua
builds the comment using the target buffer's `commentstring` and inserts it. The
inserted text is never model-authored code, and the AI still has no write tool.
Markers go in bottom-up so earlier insertions don't shift later line numbers.

Turn it off with `:MentorTodos off` or `learning = { todos = false }`.

## Configure

Defaults live in `lua/mentor/config.lua`. Common changes:

```lua
require("mentor").setup({
  window = { width = 0.25, input_height = 5 },

  -- Let it read the codebase but nothing else. Set `tools = {}` for pure chat.
  claude_cli = {
    model = "sonnet",
    tools = { "Read", "Grep", "Glob" },
  },

  context = {
    diff_target = "head", -- "worktree" | "staged" | "head"
    max_selection_lines = 200,
  },

  learning = { todos = true, marker = "TODO(human)" },

  keymaps = { review = "<leader>rr", ask = false }, -- false disables one
})
```

Switching to a free backend:

```lua
require("mentor").setup({
  provider = "openai_compat",
  openai_compat = {
    base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
    model = "gemini-2.0-flash",
    api_key_env = "GEMINI_API_KEY",
  },
})
```

Local Ollama: `base_url = "http://localhost:11434/v1"`, any `model`, and point
`api_key_env` at a variable holding a dummy value.

## Layout

```
lua/mentor/
  init.lua              setup() and the public API
  config.lua            defaults and merge
  session.lua           orchestration: prompt in, stream out, cancel, reset
  ui.lua                the side panel and streaming-safe append
  context.lua           git diff and cursor context
  todo.lua              parse TODO(human) items, insert them as comments
  prompts.lua           the tutor system prompt  <- tune this
  provider/
    init.lua            backend selection ("auto" prefers the CLI)
    claude_cli.lua      claude -p, stream-json parsing, --resume for multi-turn
    openai_compat.lua   curl + SSE
plugin/mentor.lua       commands
```

A backend implements one function:

```lua
provider.chat({
  prompt, system, state, cfg, cwd,
  on_delta = function(text) end,  -- always called on the main loop
  on_error = function(msg) end,
  on_done  = function() end,
}) --> handle with :kill(signal)
```

`state` is the backend's own scratch table: the CLI stores a `session_id` and
replays it with `--resume`; the HTTP backend keeps a `messages` list.

## Tests

```sh
make test                              # offline suite; the live spec self-skips
make test-e2e                          # adds the live spec (spends real quota)
make test-one SPEC=tests/ui_spec.lua   # just one
```

Each spec runs in its own headless nvim (`nvim --headless -u tests/minimal_init.lua`)
so specs cannot leak window, config or provider state into each other. There is
no test-framework dependency — `tests/harness.lua` is ~100 lines of `check()`
plus a fixture that builds a throwaway git repo with a real uncommitted diff.

| Spec | Covers |
|---|---|
| `wiring_spec` | Loading, commands, config merge, the sandbox flags, streaming append |
| `input_spec` | Input box geometry and keymaps, submit, context tracking from the panel |
| `ui_spec` | Busy winbar and spinner, selection attach/clear, range clamping |
| `todo_spec` | TODO parsing, last-block scoping, the on/off toggle |
| `commentstring_spec` | Comment syntax per language, indentation, bottom-up ordering |
| `e2e_spec` | Live round-trip; asserts the model changed nothing on disk |

`stub_provider()` swaps the backend for one that records the request, so the
offline specs assert on the exact prompt and system prompt sent without touching
the network.

## Known gaps

- Each turn spawns a fresh `claude` process and resumes by session id, costing
  ~1–2s of startup. A persistent process using `--input-format stream-json`
  would remove that.
- No per-project memory beyond the conversation; `CLAUDE.md` in the project root
  is the obvious hook, but `setting_sources = ""` currently excludes it.
