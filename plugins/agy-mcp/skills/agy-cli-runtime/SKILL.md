---
name: agy-cli-runtime
description: Internal helper contract for calling the `agy` CLI from Claude Code or Codex
user-invocable: false
---

# agy CLI Runtime

Do not call `agy` directly from Bash. Prefer the helper (`scripts/agy-run.sh`) or
the MCP tools (`agy_search` / `agy_ask` / `agy_look` / `agy_youtube`) over
hand-rolled `agy` CLI strings, or any other Bash activity that shells out to `agy`.

Primary helper:
- `"${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" --file <path> [--instruction <text>|--instruction-file <path>] [--rules <path> ...] [--skill <name> ...] [--model <model>] [--max-followups <n>] [--json]`
- `"${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" --prompt <text> [--rules <path> ...] [--skill <name> ...] [--model <model>] [--json]`
- `"${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" --prompt-file <path> [--rules <path> ...] [--skill <name> ...] [--model <model>] [--json]`

The round trip (write → check the facts → ask again where they drifted) is the
helper's own work, not the caller's. In `--file` mode it compares the result
against the original and, when they disagree, sends one more turn in the same
`agy` conversation naming only what drifted — the document is not resent. That
turn tells `agy` to build on its own previous answer and not to fall back to
the source text: worded as "fix these to match the original" instead, the model
answered with the untouched source in 2 of 5 runs and lost the rewrite in all 5
(measured 2026-09-17), which passes the fact check while fixing nothing.
`--max-followups` caps that (default 2). Hitting the cap is not a pass: the
helper prints what is still wrong and the `--json` payload carries
`"status": "fact_mismatch_unresolved"`.

What the machine check covers, and what it does not:
- Numbers and URLs are compared as multisets (what disappeared, what appeared).
  Numbers are taken narrowly: full-width digits are folded to ASCII, thousands
  separators are dropped, digits glued to ASCII letters (`GA4`, `v2`) are
  skipped, kanji numerals are not read, and dates decompose into their parts so
  `9月14日` and `9/14` compare equal.
- Item counts cover list items and ATX headings only.
- Proper nouns are not checked. No machine can decide them, so the helper
  does not pretend to: every run says so on stderr and in the payload
  (`fact_check.not_machine_checked`). Items enumerated inside prose are out of
  scope for the same reason. A human still has to read the diff.
- `--prompt` / `--prompt-file` run no fact check at all — there is no original
  to compare against. The payload records that instead of leaving it blank.

`--json` writes the machine payload (result body, diff for file mode, character
counts, the fact-check outcome, how many follow-ups were spent, and what was
not checked) to stdout, and moves the human-facing diff to stderr. Without
`--json` the output is unchanged: diff on stdout, character counts on stderr.

The instruction the helper defaults to aims at removing the machine-written
feel, not at shortening. Making shortness the goal moves the character count
barely at all and degrades word choice instead (measured: the only thing that
changed was picking 「確認済み」 over 「実測確認」). Ask for better word choice,
not for fewer characters.

`--rules <path>` appends a fixed document (e.g. a writing-style skill's
`SKILL.md`, or a file holding a constraint that applies to this one call only)
after the instruction/prompt, verbatim, in the order given. It can
be repeated. Do not build a file that accumulates the terms a caller has
rejected one by one (ruling of 2026-09-17): prose degrades in unlimited ways,
so such a list grows forever without ever covering them. Re-applying the
writing norm is cheaper. `--skill <name>` is a name-based shortcut for the same path:
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
- `AGY_RUN_READONLY=1` on every `agy` invocation (both `--file` and
  `--prompt`/`--prompt-file`). `agy` has no per-call tool allowlist flag, so
  the deny lives in a standing `PreToolUse` hook
  (`~/.gemini/config/hooks.json` → `scripts/agy-readonly-hook.sh`) that denies
  `write_to_file` and `replace_file_content` only while that variable is `1`.
  The hook depends on a file outside this repo, so it fails silently if that
  file goes away; the three defenses above stay in place independently of it.

Command selection:
- Use `--file` when the input already lives in a repo file. Use `--prompt` /
  `--prompt-file` only for text that has no file of its own.
- The helper's machine check already covers numbers, URLs and item counts in
  `--file` mode. What is left to the caller is reading the diff for proper
  nouns and for meaning — off the diff against the original file, not off the
  raw prompt text handed to `agy`.

Safety rules:
- Do not add `--dangerously-skip-permissions`. Media/search tool permission is
  handled by `plugins/agy-mcp/server.py`, not by this helper.
- The MCP tools remain the only supported path for search grounding
  (`agy_search`) and media understanding (`agy_look` / `agy_youtube`). This
  helper covers the plain-text call the MCP tools do not: instructing `agy` to
  rewrite text.
- Only pass text that is fine to be public. `enableTelemetry` in
  `~/.gemini/antigravity-cli/settings.json` (boolean, default `true`, the
  "Enable Telemetry" toggle under `/config` > "AI Credits & Feedback") gates
  Google's collection of data for product improvement; it's an account-level
  setting propagated to Google on login, not a local-only flag, and stops
  nothing already sent. Whether this one toggle also gates collection of
  source code and prompts ("Interactions" data per the IDE settings page and
  Terms), or the CLI reference's narrower "metric collection and crash log
  streaming" wording is the accurate scope, is not settled from primary
  sources (unconfirmed). Either way, turning it off does not stop the
  helper's own plaintext local logging (prompt text lands in
  `~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript_full.jsonl`,
  `USER_REQUEST`, measured; no deletion mechanism found) or the model calls
  themselves. Do not pass secrets, tokens, or unpublished values to `--file`
  or `--rules`.
