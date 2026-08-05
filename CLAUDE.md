# mentor.nvim

A read-only AI tutor in a Neovim side panel. It answers questions about the
project and reviews recent changes. It cannot edit files, run commands, or
install anything — that is the product, not a nice-to-have.

`README.md` covers usage and configuration. This file covers the invariants and
the things that will bite you.

## The one invariant

**The plugin must never gain write capability.** Enforcement is layered, and the
layers are deliberately not conflated:

- **Hard (capability).** `lua/mentor/provider/claude_cli.lua:19` builds the
  argv: `--tools` allowlists Read/Grep/Glob, `--disallowedTools` names the write
  tools, `--strict-mcp-config` and `--setting-sources ""` stop ambient MCP
  servers and user settings widening the sandbox. The `openai_compat` backend
  sends no tools at all.
- **Soft (pedagogy).** `lua/mentor/prompts.lua` stops it handing over finished
  implementations.

**Never move a guarantee from the hard layer to the soft one.** If a change
would make the sandbox depend on prompt wording, it is the wrong change.
`prompts.lua` is the file to iterate on freely; the argv builder is not.

`tests/wiring_spec.lua` asserts the flags, including that Edit/Write/Bash are
denied. If you touch `build_args`, that spec is the thing that must stay green.

## Layout

| File | Role |
|---|---|
| `plugin/mentor.lua` | User commands; guards on `nvim-0.10` and `vim.g.loaded_mentor` |
| `lua/mentor/init.lua` | `setup()`, keymaps; thin delegation to `session` |
| `lua/mentor/session.lua` | Orchestration: builds a prompt, drives the provider, owns busy state |
| `lua/mentor/ui.lua` | The panel — transcript window + input window, winbar, spinner |
| `lua/mentor/context.lua` | What the user is looking at: code buffer, cursor, selection, git diff |
| `lua/mentor/prompts.lua` | System prompt and request wrappers |
| `lua/mentor/brief.lua` | Finds/reads the project brief; drafts one into a buffer |
| `lua/mentor/todo.lua` | Parses `TODO(human)` items and inserts them as comments |
| `lua/mentor/store.lua` | Saved conversations on disk: write, list, prune |
| `lua/mentor/provider/` | `claude_cli` (default) and `openai_compat`, behind `resolve()` |

## Invariants worth knowing

**`ui.open()` is focus-neutral; `ui.toggle()` focuses.** `open()` restores the
previous window on purpose (`ui.lua:227`). Two things depend on it: `send()`
opens the panel while the user is still in their code buffer, so `:MentorReview`
must not yank the cursor away mid-stream; and `follow()` only auto-scrolls when
the panel is *not* the current window, so it never steals the cursor from
someone reading. Focus behaviour belongs in `toggle()`/`focus_input()`, never in
`open()`.

**Context follows the last code buffer, not the current one.** Once the panel
has an input box, the cursor is *in the panel* when a question is sent. So
`context.code_buf()` falls back to `last_code_buf`, tracked by a `BufEnter`/
`WinEnter` autocmd, and `mentor://` buffers are excluded. Anything that reads
"where is the user working" must go through `code_buf()`.

**The transcript buffer is `modifiable = false` at rest.** `append()` flips it
on and back off. Never leave it writable.

**Fill the transcript only once it has a window.** A buffer nobody is displaying
keeps its view at line 1, so text put in beforehand shows from the top when a
window finally opens — which is how a resumed conversation used to land you at
the beginning of a thread you had already read. `session.restore` calls
`ui.open` first for that reason. `ui.scroll_to_end()` then moves unconditionally,
unlike `follow()`, which declines while the panel is the current window: for a
conversation you just asked to load there is no reader to interrupt.

**The input box takes commands, not just questions.** `ui.submit` hands the line
to `session.submit`, which routes a leading `/word` to `COMMANDS` and everything
else to `ask`. The name must be a bare word, so `/usr/bin/env, what is that?`
stays a question; a slash-word that is *not* a command is refused and left in the
box rather than spent as a turn. `submit` returns whether it took the text, and
that boolean is what tells the box whether to clear.

**The scroll clamp has to run a tick late.** `WinScrolled` on the transcript
window pulls the view back so the last line stays on the bottom row. Correcting
inside the callback works for `<C-e>` and silently does nothing for `<C-f>`,
which still has scrolling of its own to finish and overwrites you — hence
`vim.schedule` and the `clamp_queued` flag. None of it is assertable headlessly:
`WinScrolled` fires from the main loop after a redraw, and a headless nvim never
redraws, so `ui_spec` checks that the autocmd is registered and leaves the
behaviour to a real UI. Drive one over `--listen` + `--remote-send` if you
change this.

**The model never authors inserted text.** For `TODO(human)`, it emits a path, a
line and a sentence; `todo.lua` builds the comment from the target buffer's
`commentstring`. Inserting model-written *code* would break the guarantee even
though no tool was involved. Markers go in bottom-up so earlier insertions do
not shift later line numbers.

**Model prose reaches the *project* only through a human keystroke.**
`:MentorInit` has the model draft a whole `MENTOR.md`, which is the one place it
is asked to produce a finished document — `prompts.brief_instructions` states
that exception explicitly so the model does not have to reconcile it against the
"never hand over finished work" rule. The draft streams into an unsaved buffer
for a file that does not exist yet (`brief.open_draft`), so `:w` keeps it and
`:q!` discards it. Never make that path write the file directly, and never let it
target a file that already exists. Prose is the limit: this is not a licence to
write code.

The one automatic write is `store.lua`, and it is deliberately outside the
project: saved conversations go to `stdpath("state")/mentor/<repo>/`, mode 0600,
so `:MentorResume` can pick a thread up in a later nvim. Nothing there is ever
read back into a *file* — it repopulates the panel and the provider handle, and
that is all. `history.save = false` turns it off. If a change would put model
text into the working tree without a keystroke, it belongs on the other side of
this line.

**The project brief is a user message, never the system prompt.** `prompts.brief`
wraps whatever is at the repo root, and that file is not vetted. Putting it in
the system slot would let a stray line in someone's `CLAUDE.md` sit downstream of
the pedagogy rules and override them. It goes in once per conversation, keyed by
`session.state.briefed_root` — re-sent after `:MentorReset`, on a backend switch,
and when the root changes mid-session, because the root follows the last code
buffer rather than cwd.

**A conversation is saved per turn, not on exit.** `session.remember` writes the
whole record every time a turn completes, because nvim does not always get to
say goodbye and surviving that is the entire point. `:MentorReset` clears
`state.conversation` rather than deleting anything: the old thread stays on disk
as its own entry and `:MentorResume` can still reach it. What resuming restores
differs by backend — `claude_cli` stores one session id and the CLI holds the
history in its own store (so a pruned session comes back as "No conversation
found", which `claude_cli.lua` handles by dropping the dead id), while
`openai_compat` has no server-side session and its saved message list *is* the
conversation.

**A model switch is not a backend switch.** `set_model` mutates
`cfg[backend].model` and stops there: every turn spawns a fresh process (or a
fresh POST) and passes the model then, so there is no session to invalidate the
way `provider_state` is invalidated when the backend changes. Never validate the
model string against a hardcoded list — the CLI is the authority on what exists,
and a list here would go stale the day a new model ships. `models` in the config
is completion candidates only.

**`commentstring` needs coaxing.** `bufadd()` + `bufload()` loads a file without
running filetype detection, so `commentstring` is empty for any file not already
open. `todo.commentstring()` forces `filetype detect`, then falls back to a
lookup table — guessing `#` would write a Python comment into a Lua file.
`tests/commentstring_spec.lua` covers this.

**Provider contract.** `chat(o)` takes `{ prompt, system, state, cfg, cwd,
on_delta, on_error, on_done }` and returns a handle with `:kill()`. `on_done`
fires exactly once, including on failure. `o.state` is the provider's to mutate
(CLI session id, or HTTP message history) and is cleared when the backend
changes. The prompt goes over **stdin**, not argv — large diffs would hit
ARG_MAX. Exit code 143 is SIGTERM from `:MentorStop` and is not an error.

## Tests

```sh
make test                              # offline suite; live spec self-skips
make test-one SPEC=tests/ui_spec.lua   # one spec
make test-e2e                          # hits the real backend, spends quota
```

Homegrown harness (`tests/harness.lua`), no plenary. One nvim process per spec
via `tests/minimal_init.lua`, so specs cannot leak window, config or provider
state into each other. `h.fixture()` builds a throwaway git repo with a real
diff; `h.stub_provider()` swaps in a recording provider.

Assertions are `h.check(label, ok, extra)` and `h.eq(label, got, want)`.

Insert mode is not assertable headlessly — `startinsert` sets a flag the main
loop consumes on re-entering normal mode, and a headless script exits first.
Test the window focus and leave insert mode to manual checking.

## Conventions

- Comments explain *why*, not what. Several of the invariants above exist as
  comments at their site; keep them there if you move the code.
- LuaCATS annotations (`---@param`, `---@return`) on anything public.
- No dependencies. Neovim 0.10+ (`vim.system`, `vim.uv`).
- Every user-facing default lives in `lua/mentor/config.lua` with a comment.
  New behaviour that someone might want off gets a config key, guarded as
  `cfg.thing ~= false` so existing configs keep working.
