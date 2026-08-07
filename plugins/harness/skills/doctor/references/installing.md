# Installing and repairing the harness (destructive — approval required)

Read this when `check.sh` reports missing wiring, or when the distributed artifacts are an
older generation. `scripts/install.sh` is idempotent, so the same command both installs and
distributes new versions.

## Posture

You are not a worker placing files — you are **deciding what to distribute**. `install.sh`
does all the mechanical work. What remains is judgement: where the code lives, which check
command to gate on, and how to describe where the project currently stands.

Two failure modes. **The first is heavier:**

1. **Reporting "install complete" while it is not actually in effect.** A `paths:` that does
   not match the language, a missing `session-head-end`, an unset `core.hooksPath` — **all of
   these die without an error**, so everyone believes it works. The first two have actually
   happened. Do not skip step 4.
2. **Fabricating 現在地.** Filling in next-directions without reading the code or the diff
   makes the canon a lie. If you have no material, write that you have no material.

**Deciding not to distribute something is a success.** Omitting `--with-log`, passing
`--skip-prepush`, or declining to install in a team repo are all correct outcomes.
The full set is not the right answer.

## 0. Survey

```sh
bash "${CLAUDE_SKILL_DIR}/scripts/survey.sh"
```

Read-only. Reports the language mix, check-command candidates, the state of any existing
harness, the artifact generation stamps, and material for 現在地.

## 1. Decide

- **Code paths**: the glob passed to the rule's `paths:`. Derive it from the survey's
  extension distribution and top-level directories. TypeScript →
  `src/**,test/**,migrations/**`; Swift → `Sources/**,Tests/**`.
- **Check command**: what pre-push runs. **Make it the same as CI** — a gate that passes
  locally and fails in CI is not a gate. Omitted, it is auto-detected the same way the
  survey does. If it includes anything heavy (network, auth, a deploy dry-run), ask the user
  whether they want to wait for it on every push.
- **docs/ relocation**: if the survey warned that `docs/` may be a published site, change it
  with `--docs-dir` — next-directions holds internal decisions and rejected options.
- **Whether to add log.md**: `--with-log` for long-lived, large projects. On small ones git
  history is enough, and an unwritten file is just clutter.
- **Codex alongside**: `--with-codex` if the survey found `.codex/` or the user uses Codex.
- **Launch root**: the hook is relative to the directory `claude` was launched from. In a
  monorepo where sessions start in a subdirectory, install from there — installing at the
  root silently deactivates it.

## 2. Run

```sh
"${CLAUDE_SKILL_DIR}/scripts/install.sh" --code-paths "src/**,test/**" \
  [--check-cmd "bun run check"] [--docs-dir docs] [--with-log] [--with-codex] [--skip-prepush]
```

It prints what it did mechanically and what is left. **Its output is authoritative** for the
remaining work; the section below only explains each item.

## 3. Fill in what the script left (□)

- **next-directions.md's `{{CURRENT_STATE}}` / `{{NEXT_STEPS}}` / `{{CATALOG}}`** — write
  from the material gathered in step 1. 現在地 should be concrete about what the next session
  would be hurt by not knowing ("there is uncommitted implementation", "a decision is awaiting
  adjudication"). Do not fabricate.
- **The rule's `{{REPO_SPECIFIC_HOTSPOTS}}`** — the places in this repo where "why not"
  comments pay off most (undocumented ways of calling an external API, domain quirks, tuning
  constants). Read the repo and write them.
- **CLAUDE.md** — if absent, `install.sh` creates it from a template. What remains is filling
  the placeholders, and keeping it **within roughly 2,000 estimated tokens** — not a line
  count; see `context-mechanics.md` for why lines are not a usable unit. What *not* to write
  (tech-stack lists, architecture overviews) is in the TODO lines the script emits.
  An existing CLAUDE.md is never touched, so if these two sections are missing, add them:

```markdown
## 情報の書き分け方針

- **コード = How** / **テスト = What** / **コミットログ = Why** / **コメント = Why not**。
- **コメントはコードと同量レベルでベッタベタに書く。** 詳細は `.claude/rules/comments.md`
  (コード編集時に自動ロード)。

## 現在地・次の作業(セッション引き継ぎ)

- 正典は **`docs/next-directions.md`** — SessionStart フック(`.claude/settings.json`)が
  頭(`session-head-end` マーカーまで)を自動注入する。作業の区切りごとに必ず更新
  (完了は打ち消し線+✅、変化は `> **YYYY-MM-DD 更新:**` を積層。計画は消さない)。
```

- **`git config core.hooksPath .githooks` in the README** — it lives in `.git/config`, so it
  is not version-controlled and is **needed once per clone**.
- **If an existing next-directions.md uses the old format** — do not overwrite. Move the
  existing body into the catalog section, create a head (現在地 and 着手順), and insert
  `<!-- session-head-end -->` at the start of a line.

## 4. Verify (do not skip)

- `bash .claude/hooks/session-start.sh` — only the head (up to the marker) should appear.
- Temporarily delete the marker line and confirm it enters fail-closed warning mode, then restore.
- pre-push:
  `echo "refs/heads/main $(git rev-parse HEAD) refs/heads/main $(git rev-parse HEAD)" | .githooks/pre-push`
  should run the checks (`git push --dry-run` does **not** run hooks).

## 5. Report

Show the files created or changed, and a summary of the 現在地 you wrote.
**Commit only when the user asks.**

## Cautions

- **Assumes a personal repository.** In a shared repo, committing `.claude/settings.json`
  plus the hook `.sh` means "code that runs at session start for everyone who clones"
  (the `.sh` body can be swapped in a PR without touching the command string in
  settings.json). Confirm with the user before installing.
- **A version stamp records the version in which that file's content last changed.**
  Differing stamps across files is normal and must not be "tidied" into agreement — doing so
  destroys the ability to detect which artifacts downstream are stale.
  Check downstream with `grep -r "harness-template v" <repo>`.
- Running the built-in `/init` after installing can overwrite CLAUDE.md without the two
  sections above. If that happens, restore them from step 3.

## Distributed artifacts (facts that affect decisions)

- **Everything is copied into the target repo.** After installing there is no runtime
  dependency on this plugin. Durable information belongs in repo files, not in a memory
  mechanism (memory is outside git, machine-specific, and invisible to other agents).
- **Codex can share the same hook scripts through a `.codex/` adapter** (`--with-codex`).
- **Only the head is injected. With no marker it does not fall back to the whole file** —
  it warns and stops (fail-closed).
- **The operating contract is backed by detectors**, not prose: the hook mechanically
  measures catalog bloat, head size (in characters and estimated tokens), and the gap
  between the canon's date and the last commit date.
- **pre-push stops things locally. `make` is not assumed** (used if present).
