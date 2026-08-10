#!/usr/bin/env bash
# harness-template v0.16.0 — セッションを畳む前の状態検査(読み取り専用)。
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
#
# 追記(2026-08-07): `-h/--help` と未知引数の検知を追加(agentskills.io の script 規約に
#   合わせる)。「読み取り専用・必ず exit 0」の契約は変えていない —— 使い方の誤り
#   (不明な引数)だけを exit 2 で区別する。
#
# 追記(2026-08-07・7原則 = ハーネスに何かを足す/変える前に採点するための7つの判断基準。
#   全文は .claude/rules/harness.md。その原則4「検知器は黙って死ぬ前提で検知器を検証する」対応):
#   git が使えない/正典ファイルが読めない、といった前提の欠落が黙って通過し
#   「要対応0件 = 畳んで問題なし」に見えていた。特に push 節は `git rev-list --count`
#   が失敗しても `|| echo 0` で 0 に丸めており、「本当に push 済み」と「比較コマンドが
#   壊れて分からない」が同じ ✓ 表示になっていた。
#   Why not 終了コードで表現しないのか: この検査は SKILL.md の `!` 記法で
#   **スキルを読んだだけで無条件に自動実行される**契約であり、`!` に置けるのは
#   「必ず成功する読み取り専用スクリプト」だけという境界を守るため。非0を返せるように
#   するとこの境界が崩れるので、終了コードは 0 のまま変えない。代わりに:
#     (1) 前提が欠けて検査できなかった箇所は `skip`(記号 ⏭)で明示し items に数える。
#         「要対応0件」に埋もれさせない —— 0件は「無い」ではなく「壊れた」を疑わせるため。
#     (2) 出力の最後に完走マーカー `=== 検査完了: N 件(tidy.sh vX.Y.Z) ===` を必ず出す。
#         途中で異常終了すると部分出力がそのまま完走した出力に見えてしまう(原則4の
#         「黙って死ぬ」そのもの)ため、終了コードの代わりにこの最終行で判定する。
set -uo pipefail

usage() {
  cat <<'EOF'
使い方: tidy.sh [-h|--help]

セッションを畳む前の状態検査(読み取り専用)。
未コミットの作業 / 正典(next-directions.md・log.md)の更新漏れ・索引の鮮度 / push 漏れ /
配布物の世代ドリフトを検査し、指摘を ⚠️(要対応)/ ✓(良好)/ ⏭(前提が欠けて検査できなかった)/
素の行(参考情報)で出す。

オプション:
  引数なし    通常の検査を実行する(既定)。
  -h, --help  これ。

使用例:
  bash tidy.sh    # git rev-parse --show-toplevel を起点にこのリポジトリを検査する

終了コード:
  0  常に。SKILL.md の `!` 記法は「必ず成功する読み取り専用スクリプト」だけを置ける
     境界を守るため、意図的にこの検査を失敗させない設計にしている(検査できなかった
     ことも指摘の1つとして本文の ⏭ で表現するだけで、非0では返さない)。
  2  使い方の誤り(不明な引数)。`!` 記法での自動実行時には起きない。

検査の完走判定(終了コードが常に0なので、代わりにこれで判定すること):
  - 出力の最終行が `=== 検査完了: N 件(tidy.sh vX.Y.Z) ===` になっているか確認する。
    この行が無ければ検査は途中で異常終了しており、それより前の出力も信用しないこと。
  - 本文中の ⏭ は「要対応0件」ではなく「前提(git・ファイル読み取りなど)が欠けて
    検査できなかった」を表す。0件に見えても ⏭ があれば壊れている可能性を疑うこと。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# 同じ scripts/ にある補助スクリプトの場所。**下で repo ルートへ cd するので、その前に
# 絶対パスへ解決しておく**(相対のままだと cd 後に見失い、「索引が古い」の誤検知になる)。
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

items=0
warn() { printf '  ⚠️ %s\n' "$*"; items=$((items+1)); }
ok()   { printf '  ✓ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
# skip: 「前提が欠けて検査できなかった」専用。⚠️/✓ と見分けが付く ⏭ を使う。
# items に数えるのは意図的 —— note 相当(無カウント)にすると「要対応0件」に埋もれ、
# 原則4「0件は壊れたを疑う」が機能しなくなる(check.sh の skip と同じ判断)。
skip() { printf '  ⏭ %s\n' "$*"; items=$((items+1)); }

# finish: 出力の最後に完走マーカーを出してから exit 0 する共通の出口。
# 出口を1関数に集約する理由は check.sh と同じ(マーカーの出し忘れ・書式のずれを防ぐ)。
finish() {
  echo
  if [ "$items" -eq 0 ]; then
    echo "畳んで問題なし。"
  else
    echo "要対応 ${items} 件。**正典の更新はセッションを閉じる前に行う**(次に開く自分のため)。"
  fi
  # ⚠️ ここの版数は先頭の `harness-template v…` 行と**手で揃える**(いま2箇所にある)。
  #    2026-08-10 に実際にズレた —— 先頭だけ v0.16.0 に上げてこちらが v0.15.0 のまま出た。
  echo "=== 検査完了: ${items} 件(tidy.sh v0.16.0) ==="
  exit 0
}

# --- 前提: git ---------------------------------------------------------------
# 旧実装は「git リポジトリではない」1行だけを出して終わっていたが、これは
# 「git コマンド自体が無い」場合と「git はあるがこのディレクトリはリポジトリの外」
# 場合を同じ文言で潰していた。理由と、なぜ個々の git 呼び出しに guard を散らさず
# ここで丸ごと打ち切るのかは check.sh の「前提: git」節と同じ(そちらを参照)。
if ! command -v git >/dev/null 2>&1; then
  echo "=== harness:tidy ==="
  skip "git コマンドが見つからない。この検査は git 依存のため実行できなかった(PATH を確認すること)"
  finish
fi
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "=== harness:tidy ==="
  skip "git リポジトリの外(または壊れたリポジトリ)なので実行できなかった。git リポジトリのルートで実行すること"
  finish
fi
root=$(git rev-parse --show-toplevel); cd "$root" || { skip "リポジトリのルート ($root) へ移動できなかった"; finish; }
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
  warn "next-directions.md が無い。/harness:doctor で導入できる"
else
  # 今日変更されたファイル(コミット済み + 未コミット)。正典自身と docs は除く。
  changed_today=$( { git log --since="$today 00:00" --name-only --format="" 2>/dev/null
                     git status --porcelain | sed 's/^...//'; } | grep -vE '^docs/|^$' | sort -u )

  for nd in "${nds[@]}"; do
    if [ ! -r "$nd" ]; then
      # 読めない正典に grep すると「日付が無い」「更新されていない」と誤読される
      # (check.sh の CLAUDE.md 節と同型の壊れ方)。読めない、と正直に言う。
      skip "$nd: 読み取り権限が無く検査できなかった"
      continue
    fi
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
      note "     完了は打ち消し線+✅、変化は「> **${today} 更新:**」を追記していく。計画は消さない。"
      [ -n "$hd" ] && [ "$hd" \< "$today" ] && note "     現在地の日付も $hd のまま。"
    fi

    # log.md は「そのコンポーネントを触った日」だけ催促する。
    logf="$(dirname "$nd")/log.md"
    if [ -f "$logf" ] && [ ! -r "$logf" ]; then
      skip "$logf: 読み取り権限が無く検査できなかった"
    elif [ -f "$logf" ]; then
      if [ "$rel_n" -gt 0 ] && ! grep -q "$today" "$logf" 2>/dev/null; then
        warn "$logf に今日の記録が無い(追記専用アーカイブ。区切りごとに末尾へ追記)"
        note '     書く条件6つ(判断した/想定が外れた/手で介入した/時間がかかった/'
        note '     やり直しが効かない変更/過去ログを読んだ)は log.md の先頭が正。'
        note '     どれにも当たらないなら `- (記録不要: 定型作業のみ)` を1行だけ残す'
        note '     —— 「黙って抜けた」と「書かないと決めた」を区別するため。'
      fi

      # 索引の鮮度。**ここでは再生成しない。--check で警告するだけ。**
      #
      # なぜ書き換えないか: tidy.sh は「読み取り専用・必ず exit 0」を契約にしており、
      # SKILL.md の `!` 記法で**スキルを読んだだけで無条件に走る**。ここに書き込みを入れると
      # 「/harness:tidy を開いただけでファイルが書き換わる」ことになり、
      # 「survey.sh は読み取り専用 / 破壊的な install.sh は `!` に置かない」と決めた境界が
      # そのまま崩れる(この repo が事故として最も警戒している形)。
      # ボツ案: ここで再生成して差分に含める。tidy はコミットまで片付けるスキルなので
      # 一見自然だが、**片付けるのは SKILL.md を読んだモデル**であって、`!` で自動実行される
      # この検査ではない。書き換えは SKILL.md の手順から明示的に呼ぶ(下のコマンドをそのまま出す)。
      if [ ! -f "$SCRIPT_DIR/log-index.sh" ]; then
        # これは「まだ入れていない」(note 相当)ではなく「検査しようとしたが
        # 補助スクリプトが無くてできなかった」なので skip —— 索引ブロック自体の
        # 有無を判定する下の note とは性質が違う(区別の理由は各分岐のコメント参照)。
        skip "$logf: 索引の鮮度は未検査(log-index.sh が無い = 配布物が v0.12.0 より古い)"
      elif ! grep -q '^<!-- log-index start -->' "$logf" 2>/dev/null; then
        # 索引未導入は「異常」ではなく「まだ入れていない」。warn(要対応カウント)にすると
        # 旧書式の log.md を持つリポジトリで毎回赤くなり、赤の意味が薄れる(nd-tasks.sh が
        # --all で未移行を警告へ落としたのと同じ判断)。ただし黙ってはいない。
        note "$logf: 索引ブロックが無い(任意。入れると全文ロードせず拾い読みできる)"
      elif ! bash "$SCRIPT_DIR/log-index.sh" --check --only index "$logf" >/dev/null 2>&1; then
        warn "$logf の日付索引が古い(または見出し書式が壊れている)。再生成してコミットに含めること:"
        note "       bash $SCRIPT_DIR/log-index.sh $logf"
      # 却下索引(v0.13.0 で追加)は**ブロック単位で別判定**する。日付索引だけを持つ
      # 配布済み log.md はまだ多く、ここを一緒に赤くすると「新しいブロックを足した日に
      # 全リポジトリが一斉に赤くなる」—— 赤の意味が消えて本物のドリフトが埋もれる。
      # だからといって --check を丸ごと外すのは論外(検知器が黙って死ぬ)。
      # よって log-index.sh の --only で**日付索引の鮮度は生かしたまま**切り分ける。
      elif ! grep -q '^<!-- rejected-index start -->' "$logf" 2>/dev/null; then
        note "$logf: 却下索引ブロックが無い(任意。却下・見送りに \`R-n\` を振ると"
        note "       「その案は前に検討したか」を日付を知らなくても引ける)"
      elif ! bash "$SCRIPT_DIR/log-index.sh" --check --only rejected "$logf" >/dev/null 2>&1; then
        warn "$logf の却下索引が古い。再生成してコミットに含めること:"
        note "       bash $SCRIPT_DIR/log-index.sh $logf"
      fi
    fi
  done
fi

echo
echo "## push"
up=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
if [ -z "$up" ]; then
  warn "upstream が無い(このリポジトリの作業は手元にしか無い)"
else
  # 旧実装は `git rev-list --count` が何らかの理由(壊れた参照・権限など)で失敗しても
  # `|| echo 0` で黙って 0 に丸めており、「本当に push 済みで差分が0」と「比較コマンド
  # 自体が壊れて分からない」が同じ ✓ 表示になっていた。$() の終了コードで区別する。
  if ahead=$(git rev-list --count "$up"..HEAD 2>/dev/null); then
    [ "$ahead" -gt 0 ] && warn "未 push が ${ahead} コミット" || ok "push 済み"
  else
    skip "upstream (${up}) との比較(git rev-list)に失敗し、push 漏れの有無を検査できなかった"
  fi
fi

# 配布物の世代ドリフト。ハーネスを配っている側/配られている側どちらでも効く。
# `v[0-9.]*` は数字0個でもマッチし、rules の説明文中の "harness-template v" を拾って
# "harness-template v " という無意味な出力になる(survey.sh の既知不具合2と同型)。
# 必ず数字1桁以上を要求する。
gen=$(grep -rhosE 'harness-template v[0-9]+(\.[0-9]+)*' .claude .githooks 2>/dev/null | sort -u | tr '\n' ' ')
[ -n "$gen" ] && { echo; echo "## 配布物の世代"; note "$gen"; note "(配布元より古ければ /harness:doctor の再実行で更新される。冪等)"; }

finish
