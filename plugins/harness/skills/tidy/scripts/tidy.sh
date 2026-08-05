#!/usr/bin/env bash
# harness-template v0.10.0 — セッションを畳む前の状態検査(読み取り専用)。
#
# 設計意図(2026-08-06):
#   doctor は「設定が正しいか」を見る。こちらは「**次のセッションが再開できる状態か**」を見る。
#   関心が違うので skill を分けた(入れる=init / 診る=doctor / 仕舞う=wrap)。
#
#   一番効くのは「コードは変わったのに正典が変わっていない」の検出。harness の運用契約
#   「作業の区切りごとに必ず更新する」は宣言だけでは腐るので、ここで機械的に見る
#   (Anthropic の long-running harness 記事にある「後続が進捗を見て勝手に完了宣言する」
#    罠は、正典が古いまま放置されると強く出る)。
#
#   読み取り専用・必ず exit 0。判断(何を書くか)はモデルに残す。
set -uo pipefail

items=0
warn() { printf '  ⚠️ %s\n' "$*"; items=$((items+1)); }
ok()   { printf '  ✓ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "(git リポジトリではない)"; exit 0; }
root=$(git rev-parse --show-toplevel); cd "$root" || exit 0
today=$(date +%Y-%m-%d)
echo "=== harness:tidy — $(basename "$root") ==="

# 正典の場所(単一プロダクト型 / コンポーネント別 pointer 型の両方に対応)。
nds=()
[ -f docs/next-directions.md ] && nds+=("docs/next-directions.md")
for f in docs/*/next-directions.md; do [ -f "$f" ] && nds+=("$f"); done

echo
echo "## 未コミットの作業"
dirty=$(git status --porcelain | wc -l | tr -d ' ')
if [ "$dirty" -eq 0 ]; then
  ok "なし(クリーン)"
else
  warn "${dirty} ファイルが未コミット。次のセッションはこれが何なのか分からない —"
  note "     コミットするか、正典の「現在地」に何をやりかけているか書くこと:"
  git status --short | head -8 | sed 's/^/       /'
fi

echo
echo "## 正典の更新"
if [ ${#nds[@]} -eq 0 ]; then
  warn "next-directions.md が無い。/harness:init で導入できる"
else
  # 今日変更されたファイル(コミット済み + 未コミット)。正典自身と docs は除く。
  changed_today=$( { git log --since="$today 00:00" --name-only --format="" 2>/dev/null
                     git status --porcelain | sed 's/^...//'; } | grep -vE '^docs/|^$' | sort -u )

  for nd in "${nds[@]}"; do
    comp=$(basename "$(dirname "$nd")")
    # マーケットプレイス型(docs/<component>/)では、そのコンポーネントに関係する変更が
    # あったときだけ催促する。repo 全体で判定すると、harness を触っただけで
    # ios-skills の正典まで「更新漏れ」と言われる(実際にそう出た)。
    if [ "$comp" = "docs" ]; then
      rel="$changed_today"                                   # 単一プロダクト型: 全変更が対象
    else
      rel=$(printf '%s\n' "$changed_today" | grep -F "$comp" || true)
    fi
    rel_n=$(printf '%s' "$rel" | grep -c . || true)

    hd=$(grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$nd" | head -1)
    nd_dirty=$(git status --porcelain -- "$nd" | grep -c . || true)
    nd_today=$(git log --since="$today 00:00" --name-only --format="" -- "$nd" 2>/dev/null | grep -c . || true)

    if [ "$rel_n" -eq 0 ]; then
      note "$nd: このコンポーネントは今日触っていない"
    elif [ "$nd_dirty" -gt 0 ]; then
      ok "$nd: 未コミットの更新あり(コミットを忘れないこと)"
    elif [ "$nd_today" -gt 0 ]; then
      ok "$nd: 今日更新済み"
    else
      warn "$nd: 関連ファイルを ${rel_n} 個変更したのに正典を更新していない"
      note "     「何をしたか」ではなく**何を確認したか**を書く(検証コマンドと結果)。"
      note "     完了は打ち消し線+✅、変化は「> **${today} 更新:**」を積層。計画は消さない。"
      [ -n "$hd" ] && [ "$hd" \< "$today" ] && note "     現在地の日付も $hd のまま。"
    fi

    # log.md は「そのコンポーネントを触った日」だけ催促する。
    logf="$(dirname "$nd")/log.md"
    if [ -f "$logf" ] && [ "$rel_n" -gt 0 ] && ! grep -q "$today" "$logf" 2>/dev/null; then
      warn "$logf に今日の記録が無い(追記専用アーカイブ。区切りごとに末尾へ追記)"
    fi
  done
fi

echo
echo "## push"
up=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
if [ -z "$up" ]; then
  warn "upstream が無い(このリポジトリの作業は手元にしか無い)"
else
  ahead=$(git rev-list --count "$up"..HEAD 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] && warn "未 push が ${ahead} コミット" || ok "push 済み"
fi

# 配布物の世代ドリフト。ハーネスを配っている側/配られている側どちらでも効く。
# `v[0-9.]*` は数字0個でもマッチし、rules の説明文中の "harness-template v" を拾って
# "harness-template v " という無意味な出力になる(survey.sh の既知不具合2と同型)。
# 必ず数字1桁以上を要求する。
gen=$(grep -rhosE 'harness-template v[0-9]+(\.[0-9]+)*' .claude .githooks 2>/dev/null | sort -u | tr '\n' ' ')
[ -n "$gen" ] && { echo; echo "## 配布物の世代"; note "$gen"; note "(配布元より古ければ /harness:init の再実行で更新される。冪等)"; }

echo
if [ "$items" -eq 0 ]; then
  echo "畳んで問題なし。"
else
  echo "要対応 ${items} 件。**正典の更新はセッションを閉じる前に行う**(次に開く自分のため)。"
fi
exit 0
