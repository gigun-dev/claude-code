---
name: tidy
description: >-
  I invoke this when a unit of work is done and the next session must be able to resume
  without this conversation — I am closing out, the user is wrapping up, or I have
  touched code without updating the canonical docs/next-directions.md. Updates the
  canon, appends to log.md, regenerates its index, and reports uncommitted work.
  Also on '/harness:tidy'.
---

# harness:tidy — close out a session

```!
bash "${CLAUDE_SKILL_DIR}/scripts/tidy.sh"
```

## Operating Posture

You are **on duty handing off to your next self**. Your concern is not whether the setup is
correct (that is `doctor`) but **whether the next session can resume without remembering
this conversation**. Do not stop at diagnosis; finish the cleanup.

Two failure modes. **The first is heavier:**

1. **Trying to tidy things this session never touched.** This has actually happened
   (2026-08-06: working only on harness, it nagged about the ios-skills canon too). The
   more it nags, the more the nagging is ignored, and it ends at "tidy is noisy, don't use
   it" — **the mechanism dies entirely.** Look only at what was touched.
2. **Committing and pushing without updating the canon.** The next session cannot read the
   intent behind the diff.

**Writing nothing is a valid outcome.** If none of log.md's conditions apply, the correct
ending is the single line `- (記録不要: 定型作業のみ)`. Hunting for something to write is the
failure; **a recorded decision not to write** is the success.

## What to do

Read the check output above, then actually do these in order:

1. **Update the canon** (see below — this is the only step needing judgement)
2. **Commit** — split into meaningful units, including the canon update
3. **Push** — pre-push runs the checks. If they fail, fix first (`--no-verify` is for emergencies)
4. Loose ends: append to log.md and **regenerate its index**; if the distributed artifacts
   are an old generation, re-run the install path in `/harness:doctor`

**Push is an outward-facing action, so show what will be pushed and confirm before running it**
(commits are local, so proceed without asking once instructed). If checks fail or a diff's
intent is unclear, ask rather than deciding on your own.

### Updating the canon (next-directions.md) — the important part

If the check says "code was touched today but the canon was not", you must write.

- **現在地**: where things stand. Especially **unverified risk** (code written but never
  run, spec-correct but not field-tested) and **decisions awaiting adjudication**.
  **Do not write an overview.**
- **着手順**: what is next, with a one-line reason — without the reason for the ordering,
  the next session will reorder it.
- **How to record completion**: write **what you verified**, not what you did.

  ```markdown
  ~~pre-push ゲートのテンプレート化~~ ✅ 完了 — 検証: 型エラーを注入して push が
     中止されることを確認(2026-08-05, store-redirect)
  ```

  With only a commit hash, a following agent reads "there is progress, so it must be done"
  and **declares completion on its own.**
- Stack changes as `> **YYYY-MM-DD 更新:**`. **Never delete the plan.**

**The `## 着手順` section has exactly one writer: `nd-tasks.sh`** (shipped with
`/harness:status`). Use `--add` / `--done` / `--note` / `--rewrite` / `--archive` rather than
hand-editing — hand edits drift the format, and numbering must scan the whole file to avoid
reusing an archived ID. 現在地 and the catalog are prose and are edited by hand.

When the stacked 更新 lines have made an item too long for the head, **fold them into the
body with `--rewrite <ID> "<new body>"`** (it drops every 更新 line on that item, prints what
it deleted, and **names any deleted line whose text it cannot find in `log.md`** — a warning,
not a failure). That is compaction, not deleting the plan: move the history into `log.md`
first — it also stays in git.

### Uncommitted work

Either commit it, or write into 現在地 what is half-finished.

### log.md (only in repos that have one)

A raw chronological record. **Append-only** at the end. Never rewrite existing entries.

**The six conditions for writing are authoritative in log.md's own header** (not copied
here). **Apply them; do not re-derive them here.** If none apply, leave the single line
`- (記録不要: 定型作業のみ)`. Headings are `## YYYY-MM-DD one-line title`. Two entries on the
same day get two headings.

**Prefix rejections and deferrals with an `R-n` ID.** Format:
`` - `R-1` **却下: 一行タイトル** — 理由(一次資料 URL / issue 番号 / 実測値)``.
Numbering is append-only with no gaps reused and no backfilling. Only ID-carrying lines make
it into the rejection index, which is what makes **"was this idea considered before?"
answerable without knowing the date.**

**After appending, regenerate the index** (also when the check above says the index is
stale). The date index and rejection index are independent, and only the region between
markers is rewritten, so it is safe to include in the same commit:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/log-index.sh"                       # date index + rejection index
bash "${CLAUDE_SKILL_DIR}/scripts/log-index.sh" --check                # freshness only, no writes
bash "${CLAUDE_SKILL_DIR}/scripts/log-index.sh" --only index --check   # for repos without a rejection index
```

`--only index|rejected` exists for exactly one purpose: keeping the date-index freshness
check alive in already-distributed log.md files that do not yet have a rejection index
(`tidy.sh` calls it in that form).

**The auto-check above (`!` notation) is read-only, so the index does not fix itself.**
Regenerating is called explicitly here, to preserve the boundary that nothing run by `!`
may write.

## Related

- **`/harness:doctor`** — is the setup sound (static check), and the install/repair path.
- **`/harness:status`** — the 着手順 listing (read-only). Ships `nd-tasks.sh`, the sole
  writer of that section.
- **`/telemetry:review`** — measured time spent in this session.
