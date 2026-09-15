#!/usr/bin/env bash
# plugins/worktree の実行口。sweep と integrate のテストを走らせて件数を合算する。
# 走らせ方: bash plugins/worktree/tests/run.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
total_pass=0
total_fail=0

run_one() {
  local out rc
  out=$(bash "$here/$1" 2>&1)
  rc=$?
  printf '%s\n' "$out"
  local p f
  p=$(printf '%s\n' "$out" | grep -o 'pass=[0-9]*' | tail -1 | cut -d= -f2)
  f=$(printf '%s\n' "$out" | grep -o 'fail=[0-9]*' | tail -1 | cut -d= -f2)
  total_pass=$((total_pass + ${p:-0}))
  total_fail=$((total_fail + ${f:-0}))
  [ "$rc" -eq 0 ]
}

sweep_rc=0
run_one test_sweep.sh || sweep_rc=1
integrate_rc=0
run_one test_integrate.sh || integrate_rc=1

echo ""
echo "worktree 合計: pass=$total_pass fail=$total_fail"
[ "$sweep_rc" -eq 0 ] && [ "$integrate_rc" -eq 0 ]
