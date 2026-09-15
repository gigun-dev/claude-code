#!/usr/bin/env bash
# plugins/worktree の sweep のテスト。使い捨てリポジトリを作って実際に判定・削除させる。
# 走らせ方: bash plugins/worktree/tests/run.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
BIN="$here/../bin/sweep"

pass=0
fail=0
work=$(mktemp -d "${TMPDIR:-/tmp}/worktree-sweep-tests.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT INT TERM

t() { # t <name> <expect 0|1> <actual grep 結果の有無>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf '✗ %s (expected=%s actual=%s)\n' "$1" "$2" "$3"
  fi
}

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

new_repo() {
  local dir="$work/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  git_q "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  echo base >"$dir/file.txt"
  git_q "$dir" add file.txt
  git_q "$dir" commit -q -m base
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# squash 取り込み済みブランチ: 祖先ではないが消せる、と判定する
# ---------------------------------------------------------------------------
repo=$(new_repo squash)
wt="$work/squash-wt"
git_q "$repo" worktree add -q -b feature "$wt"
echo added >"$wt/feature.txt"
git_q "$wt" add feature.txt
git_q "$wt" commit -q -m "add feature"
# main 側へ squash で取り込む(feature の祖先関係は main に残らない)
git_q "$repo" merge --squash feature
git_q "$repo" commit -q -m "squash merge feature"

out=$("$BIN" "$repo" 2>&1)
echo "$out" | grep -q '^  消せる ' && has_removable=1 || has_removable=0
t "squash 取り込み済みは消せると判定する" 1 "$has_removable"
echo "$out" | grep -q 'squash 取り込みと同等' && has_note=1 || has_note=0
t "squash 判定の根拠を出力に書く" 1 "$has_note"
echo "$out" | grep -q 'branch -D' && has_branch_action=1 || has_branch_action=0
t "判定表示にブランチ削除の強度(-D)を書く" 1 "$has_branch_action"

"$BIN" --apply "$repo" >/dev/null 2>&1
[ -d "$wt" ] && wt_remains=1 || wt_remains=0
t "--apply で squash 済み worktree を実際に消す" 0 "$wt_remains"
# squash 判定は内容の一致を機械で確かめているので、git の merged フラグを待たず -D で消す。
git -C "$repo" show-ref --verify --quiet refs/heads/feature && branch_remains=1 || branch_remains=0
t "squash 判定で消せたブランチは -D で一緒に消える" 0 "$branch_remains"

# ---------------------------------------------------------------------------
# 未取込ブランチ: squash 判定できないので人が決めるに残す(消さない)
# ---------------------------------------------------------------------------
repo=$(new_repo unmerged)
wt="$work/unmerged-wt"
git_q "$repo" worktree add -q -b unmerged "$wt"
echo unmerged >"$wt/unmerged.txt"
git_q "$wt" add unmerged.txt
git_q "$wt" commit -q -m "not merged anywhere"

out=$("$BIN" "$repo" 2>&1)
echo "$out" | grep -q '^  人が決める ' && has_decide=1 || has_decide=0
t "未取込ブランチは人が決めるに残す" 1 "$has_decide"
echo "$out" | grep -q '^  消せる ' && has_removable=1 || has_removable=0
t "未取込ブランチを消せると誤判定しない" 0 "$has_removable"

"$BIN" --apply "$repo" >/dev/null 2>&1
[ -d "$wt" ] && wt_remains=1 || wt_remains=0
t "--apply しても人が決めるの worktree は残す(消し急がない)" 1 "$wt_remains"
git -C "$repo" worktree remove "$wt" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# locked worktree: 触るな。--apply でも消さない
# ---------------------------------------------------------------------------
repo=$(new_repo locked)
wt="$work/locked-wt"
git_q "$repo" worktree add -q -b lockedbranch "$wt"
git_q "$repo" merge --squash lockedbranch
git_q "$repo" commit -q -m "squash merge lockedbranch"
git_q "$repo" worktree lock "$wt"

out=$("$BIN" "$repo" 2>&1)
echo "$out" | grep -q '^  触るな ' && has_hands_off=1 || has_hands_off=0
t "locked worktree は触るなに分類する" 1 "$has_hands_off"

"$BIN" --apply "$repo" >/dev/null 2>&1
[ -d "$wt" ] && wt_remains=1 || wt_remains=0
t "locked worktree は --apply でも消さない" 1 "$wt_remains"
git_q "$repo" worktree unlock "$wt"
git_q "$repo" worktree remove "$wt"

# ---------------------------------------------------------------------------
# ignore 成果物のみ残存: 取込済みでも人が決めるに残す。--purge-ignored で消せるへ
# ---------------------------------------------------------------------------
repo=$(new_repo ignored)
echo 'build/' >"$repo/.gitignore"
git_q "$repo" add .gitignore
git_q "$repo" commit -q -m gitignore
wt="$work/ignored-wt"
git_q "$repo" worktree add -q -b ignoredbranch "$wt"
git_q "$repo" merge --squash ignoredbranch
git_q "$repo" commit -q -m "squash merge ignoredbranch"
mkdir -p "$wt/build"
echo artifact >"$wt/build/out.txt"

out=$("$BIN" "$repo" 2>&1)
echo "$out" | grep -q '^  人が決める ' && has_decide=1 || has_decide=0
t "ignore 成果物のみ残存は人が決めるに残す" 1 "$has_decide"

"$BIN" --apply "$repo" >/dev/null 2>&1
[ -d "$wt" ] && wt_remains=1 || wt_remains=0
t "ignore 成果物が残る限り --apply だけでは消さない" 1 "$wt_remains"

out=$("$BIN" --purge-ignored "$repo" 2>&1)
echo "$out" | grep -q '^  消せる ' && has_removable=1 || has_removable=0
t "--purge-ignored を付ければ消せるに分類する" 1 "$has_removable"

"$BIN" --apply --purge-ignored "$repo" >/dev/null 2>&1
[ -d "$wt" ] && wt_remains=1 || wt_remains=0
t "--apply --purge-ignored で ignore 成果物ごと消す" 0 "$wt_remains"

echo ""
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
