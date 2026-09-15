#!/usr/bin/env bash
# plugins/worktree/bin/integrate のテスト。使い捨てリポジトリで実際に動かす。
# 走らせ方: bash plugins/worktree/tests/test_integrate.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
BIN="$here/../bin/integrate"

pass=0
fail=0
work=$(mktemp -d "${TMPDIR:-/tmp}/worktree-integrate-tests.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT INT TERM

t() { # t <name> <expect> <actual>
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
# 正常系: merge → commit → finish で片付く。commit 前の finish は拒否する
# ---------------------------------------------------------------------------
repo=$(new_repo clean)
wt="$work/clean-wt"
git_q "$repo" worktree add -q -b feature "$wt"
echo added >"$wt/feature.txt"
git_q "$wt" add feature.txt
git_q "$wt" commit -q -m "add feature"

"$BIN" merge "$wt" >/dev/null 2>&1
merge_rc=$?
t "merge は競合が無ければ成功する" 0 "$merge_rc"

"$BIN" finish "$wt" >/dev/null 2>&1
finish_before_commit_rc=$?
t "commit 前の finish は拒否する(取り込みが確認できないため)" 1 "$finish_before_commit_rc"
[ -d "$wt" ] && wt_remains=1 || wt_remains=0
t "commit 前の finish は worktree を消さない" 1 "$wt_remains"

git_q "$repo" commit -q -m "squash merge feature"
"$BIN" finish "$wt" >/dev/null 2>&1
finish_rc=$?
t "commit 後の finish は成功する" 0 "$finish_rc"
[ -d "$wt" ] && wt_remains=1 || wt_remains=0
t "commit 後の finish は worktree を消す" 0 "$wt_remains"
git -C "$repo" show-ref --verify --quiet refs/heads/feature && branch_remains=1 || branch_remains=0
t "commit 後の finish は取り込み確認済みなのでブランチも -D で消す" 0 "$branch_remains"

# ---------------------------------------------------------------------------
# 競合系: merge は止まり、自動解決しない。finish も拒否する
# ---------------------------------------------------------------------------
repo=$(new_repo conflict)
wt="$work/conflict-wt"
git_q "$repo" worktree add -q -b conflicting "$wt"
echo branchver >"$wt/file.txt"
git_q "$wt" add file.txt
git_q "$wt" commit -q -m "branch change"
echo mainver >"$repo/file.txt"
git_q "$repo" add file.txt
git_q "$repo" commit -q -m "main change"

out=$("$BIN" merge "$wt" 2>&1)
merge_rc=$?
t "競合があれば merge は非0で止まる" 1 "$merge_rc"
echo "$out" | grep -q '競合が残った' && has_conflict_msg=1 || has_conflict_msg=0
t "競合を自動解決せず報告する" 1 "$has_conflict_msg"

"$BIN" finish "$wt" >/dev/null 2>&1
finish_rc=$?
t "未解決の競合が残っている間 finish は拒否する" 1 "$finish_rc"
[ -d "$wt" ] && wt_remains=1 || wt_remains=0
t "未解決の競合が残っている間 finish は worktree を消さない" 1 "$wt_remains"
git -C "$repo" show-ref --verify --quiet refs/heads/conflicting && branch_remains=1 || branch_remains=0
t "未解決の競合が残っている間 finish はブランチも消さない" 1 "$branch_remains"

git_q "$repo" merge --abort

echo ""
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
