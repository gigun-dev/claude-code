#!/usr/bin/env bash
# harness-template v0.3.0 (配布元: gigun-dev/claude-code plugins/harness。配布先の世代確認はこの行を grep)
# SessionStart フック: セッション開始時にプロジェクトの「現在地」を確定的に注入する。
#
# 設計意図(caldav で確立した方式 + 2026-08-05 敵対的検証での補強):
#   - docs/next-directions.md は「頭(現在地・着手順)」+「方向性カタログ」の2部構成。
#     頭だけを注入する(全文注入は毎セッション高コストなアンチパターン)。境界は行頭の
#     `<!-- session-head-end` マーカー1行。
#   - マーカーが見つからない場合は全文注入へフォールバックせず、警告だけ注入して止める
#     (fail-closed。旧版はマーカー消失で「全文注入+肥大化警告の同時無効化」が起きた)。
#   - 肥大化(カタログ・頭)と鮮度(現在地の日付 vs 最終コミット日)は機械計測する。
#     放置に人間の裁量で気づくのは遅い/不確実。
set -euo pipefail

# フックの cwd はプロジェクトルート。CLAUDE_PROJECT_DIR があればそれを優先(堅牢化)。
doc="${CLAUDE_PROJECT_DIR:-.}/docs/next-directions.md"
[ -r "$doc" ] || exit 0  # 正典が無い/読めないなら無言で終了(フックはセッションを止めない)

# 閾値は目安。ただし警告を消すために上げるのは禁止(棚卸しが正)。棚卸し後に現況へ
# 「下げ直す」方向のみ調整してよい(上げ方向の調整を許すと検知がラチェット式に死ぬ)。
#
# **2026-08-08: 頭の予算を「行」から「文字 + 概算トークン」へ変えた。**
#   旧 HEAD_MAX_LINES=80 は**どの機構も使っていない単位**だった。実測すると行は言語構成に
#   完全に依存する —— 87行で 1,202 tok(日本語率1%)のファイルと、109行で 2,788 tok(36%)の
#   ファイルが並ぶ。**複数リポジトリへ配る以上、行を予算にすると日本語の正典だけ不当に厳しい。**
#   代わりに、実際に制約している2つの機構をそれぞれの単位で見る:
#     (1) 文字 —— この stdout は **10,000 文字**超で無言に切り詰められ、2KB のプレビューだけが
#         注入される(anthropics/claude-code#70460 / #84021 の persistHookOutput)。機械的な壁。
#     (2) 概算トークン —— **毎セッション注入されるので全セッションの実費**になる。
#         切り詰めに余裕があっても払い続ける。3,000 tok ≒ 200k 窓の 1.5%。
#   ⚠️ **この3つの値は plugins/harness/skills/next/scripts/nd-tasks.sh と一致していること。**
#      正典はこのファイル(注入の当事者であり、配布先で毎セッション走るのはこちらだから)。
#   ⚠️ カタログ側(CATALOG_MAX_LINES)が行のままなのは意図的 —— **カタログは注入されない**ので
#      文字数もトークン数も課金されない。ここで守っているのは「人が読み通せる長さ」だけで、
#      それは実際に行で決まる。単位は機構ごとに選ぶ。揃えることが目的ではない。
CATALOG_MAX_LINES=250
UPDATE_BLOCK_MAX=12
HEAD_WARN_CHARS=8000
HEAD_HARD_CHARS=10000
HEAD_WARN_TOKENS=3000

# マーカーは行頭アンカーで検出(散文中の "session-head-end" 言及で頭が切断される誤爆を防ぐ)。
marker_line=$(grep -n -m1 '^<!-- session-head-end' "$doc" | cut -d: -f1 || true)
if [ -z "$marker_line" ]; then
  echo '⚠️ docs/next-directions.md に session-head-end マーカーが見つかりません(頭の注入を停止中)。'
  echo '   現在地・着手順の直後に行頭から `<!-- session-head-end -->` の1行を復元してください。'
  echo '   それまでは docs/next-directions.md を直接読むこと。'
  exit 0
fi

echo '=== docs/next-directions.md の頭(現在地・着手順)。詳細カタログは該当節をそのとき読む。更新は「> **YYYY-MM-DD 更新:**」を積層・計画は消さない ==='

# 頭の文字数と概算トークン数。**ロケールに依存させない**のが要点 ——
# `wc -m` はロケール次第でバイト数を返す(LANG 未設定の macOS が実際にそう)ので使えない。
# 代わりに UTF-8 の構造を直接使う:
#   文字数     = 継続バイト(0x80-0xBF)を落とした残りのバイト数(1文字1バイトに潰れる)
#   ASCII 文字 = 0x00-0x7F だけ残したバイト数
# トークンは概算(**英語 ≒ 0.33 tok/字、日本語 ≒ 1.4 tok/字** を混合率で加重)。
# **概算しかない** —— Claude Code はローカルにトークナイザを持たず(2026-08-08 に
# バイナリ 2.1.222 で確認)、正確な数は `POST /v1/messages/count_tokens` で取っている。
# **フックから API は叩けない**(毎セッションのネットワーク往復・認証情報・オフラインでの沈黙)
# ので、本体が API に届かないときと同じ「文字数からの概算」に立つ。本体もそのとき
# "Token counts are estimates and may differ from actual usage." と明示する。
# ⚠️ **係数は 2026-08-08 に 0.25 / 1.1 から引き上げた**(公式: 4.7 以降の新トークナイザは
#    同じ文字列で約 30% 多い)。旧値は Opus 5 を含む現行モデルで**約 30% 過小**であり、
#    当初「過大だから安全側」と書いていたのは誤りだった。× 1.3 して 0.33 / 1.4。
# ⚠️ トークナイザはモデルの属性。フックはセッションのモデルを知れないので**多い側に固定**
#    する(旧モデルでは過大評価だが、過大は安全側)。まだ実測で較正していない。
# Why not python3/tiktoken: tiktoken は OpenAI の語彙で Claude とは別物。加えて配布先に
# python3 がある保証が無く、無いと**黙って計測が消える**。tr は POSIX で必ずある。
# ⚠️ 概算であることは出力に `≒` で明示する。
#
# ⚠️ 測っているのは頭だけだが、切り詰めの対象は**この stdout 全体**(見出し行 + 警告文も含む)。
#    見出し行は約 130 字、警告文は出ても数百字なので、8,000 / 10,000 の 2,000 字の余裕で吸収する
#    —— 余裕はそのためにある。ここを縮めるなら見出しと警告も計測に含めること。
#
# ⚠️ **係数は上書き可能な既定値であって、定数ではない。**
#    このハーネスは**エージェント非依存**(Codex アダプタを同梱する)なのに、トークナイザは
#    ベンダー固有 —— Claude と GPT では語彙が違う。**文字はテキストそのものの属性だが、
#    トークンは「テキスト × トークナイザ」の属性**なので、ここに Claude の数字を定数として
#    埋め込むと、他クライアントで黙って嘘をつく。だから env で差し替えられるようにしてある:
#      HARNESS_TOK_ASCII_PCT  ASCII 100文字あたりのトークン数(既定 33 = Claude 4.7+)
#      HARNESS_TOK_WIDE_PCT   非ASCII 100文字あたり      (既定 140 = Claude 4.7+)
#    既定値の出典は下の TOKENIZER_LABEL。**出力にもラベルを出す**ので、
#    どのトークナイザ換算の数字かが読み手に必ず伝わる。
#    (言語で加重すること自体はベンダー非依存 —— 英語中心の BPE なら日本語が高いのは共通。
#     ベンダーで変わるのは倍率だけなので、加重の構造は残して係数だけ外に出す。)
TOK_ASCII_PCT=${HARNESS_TOK_ASCII_PCT:-33}
TOK_WIDE_PCT=${HARNESS_TOK_WIDE_PCT:-140}
TOKENIZER_LABEL=${HARNESS_TOKENIZER_LABEL:-Claude 4.7+}

head_text=$(sed -n "1,$((marker_line - 1))p" "$doc")
head_chars=$(printf '%s' "$head_text" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
head_ascii=$(printf '%s' "$head_text" | LC_ALL=C tr -cd '\000-\177' | wc -c | tr -d ' ')
head_tokens=$(( (head_ascii * TOK_ASCII_PCT + (head_chars - head_ascii) * TOK_WIDE_PCT) / 100 ))
unset head_text   # 頭は下の awk が本体から直接出す。二重に持たない(大きいので)

# 頭(マーカー手前まで)を注入し、カタログ(マーカー以降)は行数と更新ブロック数を計測。
# 更新ブロックのパターンは寛容に取る(太字省略・スラッシュ日付も数える)。教える正書式は
# 太字だが、書式が少しズレただけで計測が静かに死ぬ設計にしない(敵対的検証の指摘)。
awk -v marker="$marker_line" -v maxlines="$CATALOG_MAX_LINES" -v maxblocks="$UPDATE_BLOCK_MAX" \
    -v chars="$head_chars" -v tokens="$head_tokens" -v tokenizer="$TOKENIZER_LABEL" \
    -v warnchars="$HEAD_WARN_CHARS" -v hardchars="$HEAD_HARD_CHARS" -v warntok="$HEAD_WARN_TOKENS" '
  NR < marker { print; next }
  NR == marker { next }
  {
    catalog++
    if ($0 ~ /^[[:space:]]*> (\*\*)?20[0-9][0-9][-\/].*更新(:|：)/) updates++
  }
  END {
    # 切り詰め(文字)と実費(トークン)は別の機構なので、別々に鳴らす。
    # ⚠️ hardchars は「もう切れている」——「これから気をつけて」ではない。文言を弱めないこと。
    if (chars > hardchars) {
      printf "\n✗ 頭が %d 字あります(上限 %d 字)—— **この出力はいま無言で切り詰められており、2KB のプレビューしか届いていません**(anthropics/claude-code#70460)。棚卸しするまで頭の後半は読まれません。\n", chars, hardchars
    } else if (chars > warnchars) {
      printf "\n⚠️ 頭が %d 字あります(目安 %d 字・切り詰めは %d 字)。現在地・着手順は要約し、経緯の積層はカタログ側か git 履歴へ。\n", chars, warnchars, hardchars
    }
    # ⚠️ トークンの警告は必ず**どのトークナイザ換算か**を添える。文字数の警告と違って、
    #    この数字はクライアント/モデルに依存する(このハーネスは Codex でも動く)。
    #    ラベルの無い数字は、別ベンダーで黙って嘘になる。
    if (tokens > warntok) {
      printf "\n⚠️ 頭が ≒%d トークン(%s 換算・予算 %d)。切り詰めには余裕がありますが、**毎セッション注入されるので全セッションのコスト**です。棚卸しを検討してください。\n", tokens, tokenizer, warntok
      printf "   別のトークナイザなら HARNESS_TOK_ASCII_PCT / HARNESS_TOK_WIDE_PCT で係数を差し替えられます(文字数の予算はベンダー非依存)。\n"
    }
    if (catalog > maxlines || updates > maxblocks) {
      printf "\n⚠️ next-directions.md のカタログが肥大化しています(%d 行 / 更新ブロック %d 個、閾値 %d 行 / %d 個)。\n", catalog, updates, maxlines, maxblocks
      printf "   棚卸し(次版)を実施してください — 「> 日付 更新:」積層を本文へ溶かし込み、頭を最新の現在地に更新する。\n"
      printf "   ⚠️ 閾値を上げて警告を消すのは禁止。棚卸し後に現況へ下げ直すのは可。\n"
    }
  }
' "$doc"

# 鮮度検査: 頭の「## 現在地(YYYY-MM-DD)」の日付より新しいコミットがあれば、更新漏れの可能性を警告。
# 日付粒度の比較なので当日中の連続作業では鳴らない(緩い検査。強制機構ではなく検知器)。
#
# ⚠️ **この検査は2回、書式のズレで黙って死んでいる。**
#   1回目(caldav 第5版): 全角「現在地（…）」が読めなかった → 括弧を全角/半角の両対応に。
#   2回目(2026-08-08): `## 現在地(2026-08-06・第2版)` が読めなかった。日付の**直後に閉じ括弧**を
#     要求していたため、版数などの接尾辞が付くと 0 件になる。同じ死に方の再発。
#
# **2回とも「教える書式を厳密に写した正規表現」が原因。**そこで今回は写すのをやめた ——
# **見出し行を先に特定し、その行から最初の日付を拾う**。括弧の有無・全半角・接尾辞の順序に
# 一切依存しない。原則「計測は寛容に、教える書式は厳密に」の、寛容側を本気で取る形。
# Why not 全文から最初の日付を拾う: 頭の本文に日付(更新ブロックなど)があると、それを
# 現在地の日付と誤認する。見出し行への限定はここだけは外せない。
head_line=$(sed -n "1,${marker_line}p" "$doc" | grep -m1 -E '^#+[[:space:]]*現在地' || true)
head_date=$(printf '%s' "$head_line" | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)

# **見出しはあるのに日付が取れない = 検知器が死んでいる。**黙って通さない(原則4)。
# ここを無警告で素通りさせたのが、上の2回の事故が長く見つからなかった理由そのもの。
if [ -n "$head_line" ] && [ -z "$head_date" ]; then
  printf '\n⚠️ 現在地の見出しから日付が読めません(鮮度検査が無効化されています)。見出しを `## 現在地(YYYY-MM-DD)` の形にしてください。\n   いまの見出し: %s\n' "$head_line"
elif [ -z "$head_line" ]; then
  printf '\n⚠️ 頭に `## 現在地` の見出しがありません(鮮度検査が無効化されています)。\n'
elif command -v git >/dev/null 2>&1; then
  last_commit=$(git -C "${CLAUDE_PROJECT_DIR:-.}" log -1 --format=%cs 2>/dev/null || true)
  if [ -n "$last_commit" ] && [ "$last_commit" \> "$head_date" ]; then
    printf '\n⚠️ 現在地の日付(%s)より新しいコミット(%s)があります — 頭の更新漏れの可能性。作業前に現在地を最新化してください。\n' "$head_date" "$last_commit"
  fi
fi
