---
name: doctor
description: >-
  I invoke this when I need to know whether this repository's Claude Code setup is
  sound before relying on it — I am about to trust CLAUDE.md or a path-scoped rule to
  be reaching me, I suspect a rule is silently not firing, the session-handoff harness
  is missing or from an older generation, or the user asks how the setup is doing.
  Reports bloated CLAUDE.md, rules whose `paths:` match nothing (they fail silently),
  personal settings leaking into version control, missing handoff wiring, and thin
  skill descriptions. Diagnoses by default; installs and repairs only on approval.
  Also on '/harness:doctor'.
---

# harness:doctor — setup health check, and the repair path

```!
bash "${CLAUDE_SKILL_DIR}/scripts/check.sh"
```

## Operating Posture

You are an **inspector, not a repairman and not a defense lawyer**. The default is the
strict side: every finding is either fixed or dismissed with a written reason.
**There is no third option of passing it over silently.**

Two failure modes. **The first is heavier:**

1. **Making leniency the default.** Using "this repo intentionally omits that" without
   writing down why means the next session rediscovers the same finding and redecides it.
   **That makes the check itself worthless.** Record dismissals in CLAUDE.md or
   next-directions.md — that record is the only thing that stops the rehash.
2. **Following a false positive and breaking a correct setup.** `check.sh` has been wrong
   before (2026-08-05: it read a statement of possibility as a prohibition).
   **Findings are to be adjudicated, not obeyed.** If one looks wrong, file it (below).

**A run that dismisses everything and edits nothing is a success.** Changing settings in
order to manufacture findings is a failure.

**This skill writes nothing by default.** The install/repair path below is destructive and
runs only after you show the user what will change and they agree. The name `doctor` is
borrowed from `brew doctor` — it carries the expectation of diagnosis, so diagnosis stays
the default. Breaking that would make the name lie.

**First check that the output ends with `=== 検査完了: N 件(check.sh vX.Y.Z) ===`.** Without
that line the check did not finish — a partial report reads exactly like a clean one, because
the checks that never ran report nothing. Say so and re-run; do not adjudicate a truncated
report as complete. (The marker has existed since v0.6.0; until 2026-08-08 nothing read it.)

Then read the check output and adjudicate each finding.

## Reading the findings (why each one matters)

- **CLAUDE.md is large** — every token is paid on every session, and it is re-injected
  from disk after compaction, so growth is paid forever. Move procedures to skills
  (loaded only when invoked) and file-specific constraints to `paths:`-scoped rules.
  Budgets are in characters and estimated tokens, never lines — see `references/context-mechanics.md`.
- **"always do X / never fail to Y"** — instructions are not guaranteed to be followed.
  If it must be deterministic, it is a hook.
- **"absolutely never X"** — breaks down over a long session. `permissions` or a
  `PreToolUse` hook stops it server-side, which actually holds.
- **A rule has no `paths:`** — it loads always, costing tokens during unrelated work.
- **A rule's `paths:` matches nothing** — ⚠️ **the most dangerous one.** It is not an
  error; the rule is silently disabled, so it can go years believed-active and never fire
  (this happened in swift-mcp-app on 2026-07-22).
- **`settings.local.json` is tracked** — personal permissions get shared.
- **`core.hooksPath` unset** — `.githooks/pre-push` exists but **does not run**. The
  setting lives in `.git/config`, so it is not version-controlled and is needed once per clone.
- **The canon's date is older than the newest commit** — the handoff doc was not updated.
- **A skill's description is thin** — it will not auto-trigger. Write when to use it, not
  just what it does, and phrase it as the agent's own situation (see `docs/principles.md`).

Head size is deliberately **not** reported here — `/harness:status` owns that measurement.
Three places once measured it in three different units; one canon per fact.

## Installing or repairing (destructive — approval required)

When the check reports missing wiring — no canon, no SessionStart hook, no
`core.hooksPath`, or a stale generation stamp — the fix is `scripts/install.sh`, which is
idempotent and is also how new versions are distributed to already-installed repos.

**Read `references/installing.md` and follow it.** It carries the survey step, the
decisions you must make first (code paths, check command, docs location), the exact
invocation, the placeholders only a human-facing judgement can fill, and the verification
that proves the install actually took effect.

**Never run `install.sh` straight from a finding.** Show what will change, get agreement,
then run it.

## Calibrating the token estimate against a real tokenizer (optional, opt-in)

Token figures elsewhere are **estimates** — no client ships a local Claude tokenizer, so the
harness weights characters by script. The coefficients default to Claude 4.7+ and are
overridable (`HARNESS_TOK_ASCII_PCT` / `HARNESS_TOK_WIDE_PCT` / `HARNESS_TOKENIZER_LABEL`),
because **characters are a property of the text but tokens are a property of text × tokenizer**
— and this harness also runs under Codex.

To measure exactly rather than estimate:

```sh
# local, nothing leaves the machine — for Codex / GPT-family clients
bash "${CLAUDE_SKILL_DIR}/scripts/calibrate.sh" --gpt <english-file> <japanese-file>

# exact Claude counts — needs ANTHROPIC_API_KEY; the endpoint is free (rate-limited only)
bash "${CLAUDE_SKILL_DIR}/scripts/calibrate.sh" --claude <english-file> <japanese-file>
```

**Pass two or more files with clearly different script mixes.** There are two unknowns, so
one file cannot determine them (an earlier version fixed one and solved for the other; it
produced a negative coefficient on an English-heavy file). It prints `export` lines to paste.

⚠️ **`--claude` sends the full contents of those files to the Anthropic API.** Canon files
carry internal decisions and rejected options — show the user which files and get agreement
before running it. `--gpt` is entirely local. This script is deliberately **not** in the `!`
block above: `!` may only hold scripts that always succeed, are read-only, and stay offline.

## When the check itself is wrong (false positive or blind spot)

**File it on the spot.** The fix belongs upstream (`gigun-dev/claude-code`), but you notice
it while working downstream, so without a cross-repo path the "fix it later" is lost:

```sh
"${CLAUDE_SKILL_DIR}/scripts/report.sh" --title "<one-line>" --note "<what you expected>"
```

**It splits the report in two, by whose data it is:**

| | Whose | Where it goes |
|---|---|---|
| **The defect** | the harness's | filed into the upstream `## 着手順` via `nd-tasks.sh --add`, which assigns an ID |
| **The evidence** (doctor output, the actual offending lines) | **this repo's** | `./.harness/reports/<ID>.md` — stays at this repo's visibility |

The ID is the only link. Whoever can see this repo can see the evidence; whoever cannot,
never learns it exists. **Nobody has to judge visibility — the location makes it correct.**

**Default is draft only: without `--create` it writes nothing.** Show the draft to the user
and get agreement first. `--github` additionally opens an issue upstream; it queries both
repos' visibility with `gh` and **refuses on a mismatch, and refuses when it cannot tell.**

⚠️ **What that gate does not cover.** It protects the automatic attachment; it cannot
protect prose you write in `--title` / `--note`, and the upstream canon itself lives in a
repo that may be public. **Do not put this repo's specifics — file contents, incident
details, commit SHAs — in those flags.** They belong in the evidence file. An earlier
version attached doctor output unconditionally and published a private repo's CLAUDE.md
lines to a public issue; deleting the issue did not undo it (GH Archive ingests hourly).

## When you doubt the criteria themselves

**Last verified 2026-08-08. If more than 180 days have passed, re-ground on primary
sources before using this** — thresholds and checks go stale as Claude Code changes.

1. Fetch the best-practices article live (do not judge from memory or a summary):
   https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more
2. Ground only the items in question against the official docs: https://code.claude.com/docs/
   — hooks / memory (rules, CLAUDE.md) / plugins / skills.
3. If anything changed, update the thresholds in `scripts/check.sh` and the date here.
4. `references/context-mechanics.md` holds the measured per-file context mechanics
   (lifetimes, compaction survival, the 10,000-character SessionStart limit, why token
   counts can only be estimated). `references/audit-2026-08-05.md` is the previous state;
   the diff against the live article is what changed.

## Related

- **`/harness:status`** — lists what to work on next from the canon (read-only).
- **`/harness:tidy`** — closes out a session: canon update, log append, uncommitted work.
- **`/cclens:doctor`** — not a static check but **measured actual usage** (failure habits,
  unused config, always-on cost).
- **`/telemetry:review`** — per-tool time and failures from Langfuse traces.
- Before a large design change, run adversarial verification:
  `references/adversarial-verification.md`.
