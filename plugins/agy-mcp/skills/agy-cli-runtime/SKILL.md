---
name: agy-cli-runtime
description: Internal helper contract for calling the `agy` CLI from Claude Code or Codex
user-invocable: false
---

# agy CLI Runtime

Do not call `agy` directly from Bash. Prefer the helper (`scripts/agy-run.sh`) or
the MCP tools (`agy_search` / `agy_ask` / `agy_look` / `agy_youtube`) over
hand-rolled `agy` CLI strings, or any other Bash activity that shells out to `agy`.
The `codex:agy-ja-writer` agent must call the helper, not `agy` directly.

Primary helper:
- `"${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" --file <path> [--instruction <text>|--instruction-file <path>] [--rules <path> ...] [--skill <name> ...] [--model <model>]`
- `"${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" --prompt <text> [--rules <path> ...] [--skill <name> ...] [--model <model>]`
- `"${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" --prompt-file <path> [--rules <path> ...] [--skill <name> ...] [--model <model>]`

`--rules <path>` appends a fixed document (e.g. a writing-style skill's
`SKILL.md`, or a plain text file listing terms the caller has individually
rejected) after the instruction/prompt, verbatim, in the order given. It can
be repeated. `--skill <name>` is a name-based shortcut for the same path:
it resolves `<name>` against this repo's `plugins/*/skills/<name>/SKILL.md`
(the caller doesn't need to know which plugin owns it) and feeds the
resolved file into the same `--rules` pipe — there is only one concatenation
implementation, so `--rules` and `--skill` entries interleave in the order
given. `agy` itself has a skill mechanism (`skills.json`/`.agents/`), but
its skills use progressive disclosure — the body is only read if the model
decides to — which is not reliable enough for a single rewrite call to bet
on; `--rules`/`--skill` force the text into the prompt instead.

What the helper absorbs (do not reimplement these elsewhere):
- The `-p=<text>` join. `agy -p "..." --model X` lets `-p` swallow `--model` as
  the prompt (measured). The helper always uses `=`.
- The default model for Japanese final-draft prose: `gemini-3.8-flash-high`.
- Stripping the leading preamble sentence Gemini always prepends (e.g. "ご提示
  いただいた文章を…整えました") by having `agy` wrap the real answer in sentinel
  markers and extracting only what is between them. Callers get body text only.
- Long prompts/files, passed to `agy` in a way that survives shell metacharacters
  and newlines.
- `--file` mode never overwrites the source file: it prints a unified diff
  (original vs. agy's draft) plus an original-vs-result character count to
  stderr. Applying the diff is the caller's decision, not the helper's.
  This is enforced, not just intended: `agy`'s own settings
  (`~/.gemini/antigravity-cli/settings.json`, `agentMode: accept-edits` /
  `toolPermission: always-proceed`) let it call file-write tools without
  approval, and `agy` also `ls`s its CWD and opens absolute paths it finds in
  the prompt text (measured). The helper never puts the source file's
  absolute path in the prompt (only its basename), runs `agy` with its CWD
  isolated in a fresh empty directory per call, and diffs the source file's
  content against a stashed copy after the call — if it changed anyway, the
  helper restores the stashed content and prints a warning to stderr before
  returning the diff.

Command selection:
- Use `--file` when the input already lives in a repo file. Use `--prompt` /
  `--prompt-file` only for text that has no file of its own.
- Fact checks (numbers, URLs, proper nouns, item counts) and the character-count
  comparison must be read off the diff against the original file — not off the
  raw prompt text handed to `agy`.

Safety rules:
- Do not add `--dangerously-skip-permissions`. Media/search tool permission is
  handled by `plugins/agy-mcp/server.py`, not by this helper.
- The MCP tools remain the only supported path for search grounding
  (`agy_search`) and media understanding (`agy_look` / `agy_youtube`). This
  helper covers the plain-text call the MCP tools do not: instructing `agy` to
  rewrite text.
- Only pass text that is fine to be public. Two destinations are confirmed:
  `google-antigravity/antigravity-cli`'s README ("Terms of Service & Data
  Use") states Google collects Interactions data by default; the README lists
  an opt-out but its setting key is not found in the README or in
  `~/.gemini/antigravity-cli/settings.json` (unconfirmed). Separately, the
  full prompt text lands in plaintext in
  `~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript_full.jsonl`
  (`USER_REQUEST`, measured); no deletion mechanism was found. Do not pass
  secrets, tokens, or unpublished values to `--file` or `--rules`.
