---
name: status
description: >-
  I invoke this when I need to know what to work on next in this repository — I am
  starting on it, I just closed something out, or the user asks what remains. Reads the
  `## 着手順` checklist and reports open items with their completion criteria, done
  items with evidence, and items ready to be archived, plus the size of the head that
  SessionStart injects. Read-only. Also on '/harness:status'.
disable-model-invocation: true
---

<!-- Why `disable-model-invocation: true`: listing is something you reach for explicitly.
     Auto-firing on any loosely related turn puts a dozen-row table into context every
     time, and this skill has no side effect other than displaying — so there is no case
     where auto-firing wins. Invoke it on '/harness:status' or when the user asks.
     The reason lives here rather than in a YAML comment in the frontmatter because a
     frontmatter parse failure **silently disables the skill** — the failure mode this
     repository hates most. -->

# harness:status — what to work on next

## Operating Posture

You are a **read-only reporter**. You do exactly ONE thing: read the `## 着手順` section
of `next-directions.md` and list it. **You do not modify a single byte.**

Three failure modes, **heaviest first**:

1. **Reporting zero items as "there is no work."** An empty list and a broken detector
   look identical, so **zero means "suspect broken" first.** If the script exits non-zero,
   say "the format or the parser is broken", never "there are no tasks" (see fail-closed below).
2. **Writing to the canon to "tidy it up."** Two writers split the canon. Marking things
   done and moving archived items belong to **`/harness:tidy`**; setup health belongs to
   **`/harness:doctor`**, which also owns install and repair.
3. **Summarizing the table and dropping items.** Show the script's output as-is.

**A run that lists things and fixes nothing is the normal outcome.** If you find repos that
have not migrated, this skill does not migrate them — reporting the count is enough.

## Usage

```sh
bash "${CLAUDE_SKILL_DIR}/scripts/nd-tasks.sh"                 # this repository
bash "${CLAUDE_SKILL_DIR}/scripts/nd-tasks.sh" --all           # across ~/ghq/github.com/*/*
bash "${CLAUDE_SKILL_DIR}/scripts/nd-tasks.sh" --format json   # for agents
bash "${CLAUDE_SKILL_DIR}/scripts/nd-tasks.sh" --lint          # format check only (non-zero on violation)
```

**`--help` is authoritative for the format read, the JSON fields, the checks, and the exit
codes.** Do not copy them here — only the copy goes stale (it already did: exit code 3 was
added while the copy here still said 0–2).

The `!` notation (auto-run on skill load) is deliberately **not used** here, for two
reasons: this skill is explicitly invoked so there is nothing to gain from running at load
time, and `!` may only hold scripts that **always succeed** — `nd-tasks.sh` is fail-closed
and exits non-zero, so it does not qualify.

### Writing (status does not write; `/harness:tidy` calls these)

**Never hand-edit `## 着手順`. Let these four write it.** As long as the script is the only
writer, format drift cannot happen structurally — and numbering scans the whole file, so
archived IDs are never reused. Below, `nd-tasks.sh` abbreviates the full path above:

```sh
nd-tasks.sh --add "<summary>" --criteria "<completion criteria>"   # file (auto-numbered ID)
nd-tasks.sh --done <ID> --evidence "<what you verified>"           # close (evidence required)
nd-tasks.sh --note <ID> "<text>"                                   # append an update
nd-tasks.sh --archive [--apply]                                    # move to 完了記録 (dry-run by default)
```

## Three buckets — including "no longer needs to be in the head"

Without the third bucket the canon grows monotonically.

1. **次にやること** — `[ ]` items. **Report the completion criteria too** — knowing what
   would close an item is the main point.
2. **完了(証拠あり)** — `[x]` items that carry an evidence line.
3. **整理対象** — all `[x]` items, with or without evidence. Once closed, the reason to
   keep them in the head is gone, so they are **candidates for the catalog or `log.md`**.

2 and 3 may overlap. `(移行: 証拠なし)` is a label meaning "do not treat as verified" — an
**independent axis** from whether an item should be archived.

**Moving them is `/harness:tidy`'s job. status reads and reports; it does not move.**

## Head size — the main health metric of the cross-repo board

Reports the head of `docs/**/next-directions.md` (start of file to `<!-- session-head-end`)
in **two units, because two different mechanisms constrain it**:

- **Characters — truncation.** SessionStart stdout is silently truncated above
  **10,000 characters**, injecting only a 2KB preview (anthropics/claude-code#70460, #84021).
  Warn above 8,000; above 10,000 **it is being cut right now**.
- **Estimated tokens — recurring cost.** The head is injected every session, so this is
  paid on every session even when nothing is truncated. Warn above 3,000.
- **No marker** — in a repo whose hook injects the head, **injection has stopped** (violation).
  In a pointer-style repo there is no injection to stop, so it is only a warning.

**Lines are reported as a reference value only, never as a budget** — no mechanism uses
lines, and line counts swing more than 2× with the ratio of Japanese to English.

⚠️ **Raising a threshold to silence a warning is forbidden.** Only lowering it back toward
current reality, after an actual cleanup, is allowed.

## fail-closed — zero items is not "no tasks"

**Never read zero items as "no work."** But zero has two causes and they are handled differently:

| Cause | Verdict | Meaning |
|---|---|---|
| **Not migrated** (`no-section` / `not-migrated`) | violation alone / **warning under `--all`** | No section, or no `- [` lines at all = not yet a checklist. **A known state, not an anomaly** |
| **Drift** (`empty-section` / `malformed`) | **always a violation** | `- [` lines exist but cannot be read = **something that used to parse no longer does.** A real anomaly |

Not-migrated is downgraded to a warning only under `--all` because the cross-repo board is
looked at constantly — one unmigrated repo would make it permanently red, and **a permanently
red signal means nothing, burying real drift** (the same logic as forbidding threshold
raises: a detector dies just as thoroughly by crying wolf). The unmigrated count always
appears in the summary line, so "not done yet" still comes through as a number.

If it exits non-zero, run `--lint` and **report whether the format or the parser needs fixing.**

## Required Output Format

Show the script's markdown table **verbatim**. Do not summarize away items. Then add at
most one or two lines:

- The three counts (`次にやること N / 完了(証拠あり) M / 整理対象 K`)
- If any head exceeds a threshold: state it and point at `/harness:tidy`
- If there are violations (non-zero exit): **say "the format or parser is broken", never
  "there are no tasks"**
- Under `--all`, if anything is unmigrated, add the count (**a warning, not a failure**;
  migrating means rewriting the canon to the template format that `/harness:doctor` distributes)

## Feeding the built-in task list

You may push open items into `TaskCreate`. **One way only: markdown → task list.**

**Never write task-list changes back into the canon.** Doing so makes "which one is true"
undecidable afterwards. The canon is updated by editing its text, and reflecting that is
`/harness:tidy`'s job. Treat the task list as a scratchpad for this session only.

## Related

- **`/harness:tidy`** — closes out a session: canon update, archiving, commit, push.
- **`/harness:doctor`** — static health check of the setup, and the install/repair path.
