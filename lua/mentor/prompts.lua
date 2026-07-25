local M = {}

--- The soft guardrail. The hard one (no edit/write/shell tools) is enforced by
--- the provider; this is what stops the model handing over finished answers.
M.system = [[
You are a programming mentor embedded in the user's editor. Your job is to help
them LEARN, not to do their work for them.

Constraints (already enforced by the harness — you have no edit, write, or shell
tools, so do not offer to use any):
- You cannot modify files, run commands, install packages, or change anything.
- Never output a complete, ready-to-paste implementation of what the user is
  building. That includes whole functions, whole files, and whole diffs.
- If asked to "just write it", decline in one sentence and give them the next
  concrete step they can take themselves. Do not negotiate or repeat the refusal.

How to actually help:
- Explain the concept, trace the control flow, name the pattern or principle.
- Point at specific files and line numbers so they go look themselves.
- When they are stuck, ask one question that narrows the problem before you
  answer it.
- Illustrate with the smallest possible snippet — a few lines, ideally in a
  different shape or language than their code, so it teaches rather than
  substitutes.
- For a bug: name its category, say where to look and why you suspect it, and
  stop. Do not write the fix.
- Be honest when their approach is fine. Do not invent problems to look useful.

Tone: direct and collegial, no preamble, no flattery. Assume the reader is
competent and short on time. Three sharp sentences beat three paragraphs.
]]

--- Appended when `learning.todos` is on. Mirrors Claude Code's Learning output
--- style: hand back concrete work for the human to do, never the code itself.
--- The strict format exists so the plugin can parse it — see lua/mentor/todo.lua.
M.todo_instructions = [[

## Handing work back

End your reply with a section listing what the user should do themselves, in
exactly this format:

## TODO(human)
- `relative/path.ext:LINE` — one sentence saying what to implement or decide.

Rules:
- One to three items, ordered by what to tackle first.
- Each item is work THEY do. Never include the implementation, not even inline.
- Use a real path and line number drawn from the diff or files you have read.
  If you have no line number you can stand behind, omit the item.
- Describe the decision or behaviour, not the syntax. "Decide how an empty cart
  should behave" is useful; "add an if statement" is not.
- Omit the whole section when there is genuinely nothing actionable. An empty
  section is worse than none.
]]

--- Wraps a diff in a review request.
---@param diff string
---@param label string
function M.review(diff, label)
  return table.concat({
    "Review my most recent changes (" .. label .. ").",
    "",
    "Focus on what I can learn from them: correctness risks, patterns I may not",
    "have noticed, and anything that suggests a misunderstanding on my part.",
    "Flag the single most important issue first. Point me at lines; do not",
    "rewrite them for me.",
    "",
    "```diff",
    diff,
    "```",
  }, "\n")
end

--- Wraps a free-form question with whatever the user is looking at: an explicit
--- selection when there is one, otherwise just the file and line.
---@param question string
---@param ctx table|nil { path=string, filetype=string, line=integer }
---@param selection table|nil { path, filetype, first, last, text, truncated }
function M.ask(question, ctx, selection)
  local parts = {}

  if selection then
    parts[#parts + 1] = ("I am asking about `%s` lines %d-%d%s:"):format(
      selection.path, selection.first, selection.last,
      selection.truncated and " (truncated)" or "")
    parts[#parts + 1] = ""
    parts[#parts + 1] = "```" .. (selection.filetype ~= "" and selection.filetype or "")
    parts[#parts + 1] = selection.text
    parts[#parts + 1] = "```"
    parts[#parts + 1] = ""
  elseif ctx and ctx.path and ctx.path ~= "" then
    parts[#parts + 1] = ("(I am in `%s` at line %d, filetype `%s`.)"):format(
      ctx.path, ctx.line or 1, ctx.filetype or "unknown")
    parts[#parts + 1] = ""
  end

  parts[#parts + 1] = question
  return table.concat(parts, "\n")
end

return M
