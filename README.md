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
{ "Juano97/mentor.nvim", opts = {} }
```

Then `:checkhealth mentor` to confirm the backend and the sandbox settings.

## Use

| Command | Default map | What it does |
|---|---|---|
| `:Mentor` | `<leader>mm` | Toggle the panel (right split, ~20% wide); opens straight into the input box |
| `:MentorAsk [text]` | `<leader>ma` | Ask a question; prompts if you give no text |
| `:MentorReview` | `<leader>mr` | Review your most recent changes |
| `:MentorInit` | — | Draft a project brief for this repo; you review and save it |
| `:MentorModel [name]` | — | Show or switch the model; no argument reports the current one |
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

## Choosing a model

Pin one in your config:

```lua
require("mentor").setup({
  claude_cli = { model = "opus" },  -- alias, or a full model id
})
```

The string is passed straight to `claude --model`, so anything the CLI accepts
works — an alias like `opus`/`sonnet`/`haiku` for the current model of that
size, or an exact id when you want to hold a specific version. Leave it `nil`
and the CLI's own default applies. `claude --model` is the authority on what
exists; the plugin never validates the string, so a new model works the day it
ships without a plugin update.

Switch without restarting:

```vim
:MentorModel opus        " from the next turn on
:MentorModel             " which one am I talking to?
:MentorModel default     " back to the CLI's default (claude_cli only)
```

This does **not** reset the conversation. Every turn spawns a fresh process and
passes `--model` then, so a switch mid-thread just changes who answers next —
useful for putting a hard question to a bigger model and dropping back down.
The transcript marks the first answer and every switch after it:

```
▍mentor — opus
Because the discount is applied after rounding …
```

On the HTTP backend `:MentorModel` sets `openai_compat.model` instead. Fill in
`openai_compat.models` to get completion for whatever your endpoint serves;
`claude_cli.models` is prefilled with the aliases.

For automatic downgrade under load, `extra_args` reaches the rest of the CLI:
`claude_cli = { extra_args = { "--fallback-model", "sonnet" } }`.

## The project brief

A question about one file rarely needs the whole project explained, but a
question about *this* project usually does. So mentor looks for a brief at the
repo root — `MENTOR.md`, then `CLAUDE.md`, then `AGENTS.md`, first hit wins — and
sends it once at the start of a conversation. Nothing at the root means nothing
sent, so single-file work is unaffected.

The plugin reads the file itself rather than leaving it to the backend: with
`setting_sources = ""` the CLI does not pick up a project `CLAUDE.md`, and the
HTTP backend never would. Doing it here means both behave the same.

It goes in as a **user** message, not part of the system prompt. Whatever sits at
your repo root is not allowed to land underneath the teaching rules and quietly
override them.

Sent once per conversation — `:MentorReset` starts a new one, and so does opening
a file in a different repo.

### Writing one

`:MentorInit` drafts one when there is none:

```
:MentorInit
  → mentor reads the project with Read/Grep/Glob
  → MENTOR.md opens in a split, unsaved, filling in as it streams
  → you edit it and :w — or :q! and nothing ever existed
```

**The draft never touches disk.** It streams into an ordinary buffer for a file
that does not exist yet, so `:w` creates it and `:q!` throws it away. That is the
same bargain as `TODO(human)`: the plugin does the mechanical part, you decide
what is kept. It also refuses to run when a brief already exists — replacing one
is a job for you and your editor.

It drafts `MENTOR.md` rather than `CLAUDE.md` on purpose. A `CLAUDE.md` is written
for an agent that does the work; a tutor's brief wants different things in it, and
overwriting the file your coding agent owns is a bad surprise. Existing ones are
read, never written.

Turn reading off with `context = { project_brief = false }`. `:MentorInit` still
refuses to overwrite a file that is there.

## Configure

Defaults live in `lua/mentor/config.lua`. Common changes:

```lua
require("mentor").setup({
  -- focus_on_open=false makes :Mentor only reveal the panel, cursor unmoved.
  window = { width = 0.25, input_height = 5, focus_on_open = true },

  -- Let it read the codebase but nothing else. Set `tools = {}` for pure chat.
  claude_cli = {
    model = "sonnet", -- nil defers to the CLI; :MentorModel switches at runtime
    tools = { "Read", "Grep", "Glob" },
  },

  context = {
    diff_target = "head", -- "worktree" | "staged" | "head"
    max_selection_lines = 200,

    project_brief = true, -- false to never read one
    -- Searched at the repo root; the first entry is what :MentorInit drafts.
    project_brief_files = { "MENTOR.md", "CLAUDE.md", "AGENTS.md" },
    max_brief_lines = 200,
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
  brief.lua             find/read the project brief, draft one into a buffer
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
| `model_spec` | Model selection per backend, runtime switching, transcript labelling |
| `brief_spec` | Brief discovery and precedence, sent once per conversation, `:MentorInit` drafting to a buffer and not to disk |
| `commentstring_spec` | Comment syntax per language, indentation, bottom-up ordering |
| `e2e_spec` | Live round-trip; asserts the model changed nothing on disk |

`stub_provider()` swaps the backend for one that records the request, so the
offline specs assert on the exact prompt and system prompt sent without touching
the network.

## Known gaps

- Each turn spawns a fresh `claude` process and resumes by session id, costing
  ~1–2s of startup. A persistent process using `--input-format stream-json`
  would remove that.
- The project brief is re-read from disk on each new conversation but not while
  one is running, so editing it mid-conversation has no effect until
  `:MentorReset`.
