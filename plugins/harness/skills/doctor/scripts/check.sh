#!/usr/bin/env bash
# harness-template v0.11.0 — ベストプラクティス遵守を機械的に検査する(読み取り専用)。
#
# 設計意図(2026-08-05):
#   機械判定できる項目だけを確定的に検査する。スキルやハーネスを作った直後に
#   「本当に守れているか」を答えるのが目的。
#
#   判定基準の出典はベストプラクティス記事(要旨は ../references/audit-*.md)。
#   ただし**閾値や規約は Claude Code 側の仕様変更で陳腐化する**ので、SKILL.md の
#   「判定基準そのものを疑うとき」で一次情報を確認したら、ここの数字も見直すこと。
#
#   読み取り専用・必ず exit 0(検査が作業を止めない)。指摘は ⚠️、致命は ✗、良好は ✓、
#   前提が欠けて検査できなかったものは ⏭。
#
# 追記(2026-08-07・H-10 / --help 整備):
#   (1) pre-push 検査の起点を `.githooks/` 固定から `git config core.hooksPath` の実値へ
#       変えた。詳細は該当箇所のコメント(「pre-push」節)を参照 —— dotfiles
#       (`core.hooksPath=git/hooks`)で「pre-push が無い」と誤検知していた実物のバグ修正。
#   (2) `CLAUDE_MD_MAX` を 200 → 80 に下げた。**→ 2026-08-08 に行という単位ごと廃止した**
#       (`CLAUDE_MD_WARN_TOKENS` / `CLAUDE_MD_HARD_CHARS` へ)。経緯は変数定義の直上コメント。
#   (3) `-h/--help` と未知引数の検知を追加(agentskills.io の script 規約に合わせる)。
#       この検査自体は元々「読み取り専用・必ず exit 0」が契約なので、それは変えていない
#       —— 引数の誤り(使い方の誤り)だけは exit 2 で区別する。
#
# 追記(2026-08-07・盆栽の7原則・原則4「検知器は黙って死ぬ前提で検知器を検証する」対応):
#   これまで「前提が欠けて検査できなかった」と「検査した結果、指摘が0件だった」が
#   出力上も終了コード上も区別できなかった —— python3 が無いと skill の description
#   長の判定が黙って通過し、git が無い/リポジトリの外だと `git ls-files` などが軒並み
#   空振りして **rules の paths が実は有効なのに「どのファイルにもマッチしない」と
#   誤って ✗ を出す**、という実物の壊れ方があった。
#   Why not 終了コードで表現しない: この検査は SKILL.md の `!` 記法で
#   **スキルを読んだだけで無条件に自動実行される**。`!` に置けるのは「必ず成功する
#   読み取り専用スクリプト」だけ、という境界をこのハーネスは明示的に守っている
#   (だから nd-tasks.sh のような fail-closed で非0を返す検知器は `!` に置いていない)。
#   非0を返せるようにするとこの境界そのものが壊れるので、終了コードは 0 のまま変えない。
#   代わりに:
#     (1) 前提(git・python3・ファイル読み取り)が欠けて検査できなかった箇所は `skip`
#         (記号 ⏭。⚠️/✗/✓ と区別できる絵文字を選んだ)を1件として出し、findings に数える。
#         「指摘0件」に埋もれさせない —— 0件は「無い」ではなく「壊れた」を疑わせるため。
#     (2) git 自体が無い/リポジトリの外という**この検査全体の土台が壊れているケース**は、
#         個々の git 呼び出しごとに guard を散らすと壊れ方が中途半端(一部だけ壊れた出力)
#         になるので、冒頭で丸ごと ⏭ 1件を出して打ち切る(finish 経由)。CLAUDE.md 単体の
#         チェックなら git が無くても pwd 起点で続行できなくはないが、rules / 個人設定分離 /
#         セッション引き継ぎ / pre-push の各節はいずれも git 前提で、その状態で続行すると
#         誤った ✗/⚠️ を積み増すほうが実害が大きいと判断した(親への論点として最終報告に残す)。
#     (3) 出力の最後に完走マーカー `=== 検査完了: N 件(check.sh vX.Y.Z) ===` を必ず出す。
#         Why not 完走判定も終了コードでやらないのか: 上と同じ理由(`!` の境界)に加え、
#         **途中で異常終了すると、それまでの部分出力がそのまま「完走した出力」に見えてしまう**
#         (原則4 の「黙って死ぬ」そのもの)。終了コードは常に 0 なので判定に使えないが、
#         最後の1行がこのマーカーかどうかは出力だけで機械的に判定できる —— マーカーが無ければ
#         それより前の内容も含めて信用しないこと。
set -uo pipefail

usage() {
  cat <<'EOF'
使い方: check.sh [-h|--help]

ベストプラクティス遵守を機械的に検査する(読み取り専用)。
CLAUDE.md・.claude/rules・個人設定の分離・セッション引き継ぎハーネス(next-directions.md /
SessionStart フック / pre-push)・skills を検査し、指摘を本文へ
⚠️(要検討)/ ✗(致命)/ ✓(良好)/ ⏭(前提が欠けて検査できなかった)/ 素の行(参考情報)で出す。

オプション:
  引数なし    通常の検査を実行する(既定)。
  -h, --help  これ。

使用例:
  bash check.sh    # git rev-parse --show-toplevel を起点にこのリポジトリを検査する

終了コード:
  0  常に。SKILL.md の `!` 記法は「必ず成功する読み取り専用スクリプト」だけを置ける
     境界を守るため、意図的にこの検査を失敗させない設計にしている(検査できなかった
     ことも指摘の1つとして本文の ⏭ で表現するだけで、非0では返さない)。
  2  使い方の誤り(不明な引数)。これは `!` 記法での自動実行時には起きない
     (呼び出し側が引数を渡さないため)ので、上の境界とは無関係に区別できる。

検査の完走判定(終了コードが常に0なので、代わりにこれで判定すること):
  - 出力の最終行が `=== 検査完了: N 件(check.sh vX.Y.Z) ===` になっているか確認する。
    この行が無ければ検査は途中で異常終了しており、それより前の出力も信用しないこと。
  - 本文中の ⏭ は「指摘0件」ではなく「前提(git・python3・ファイル読み取りなど)が
    欠けて検査できなかった」を表す。0件に見えても ⏭ があれば壊れている可能性を疑うこと。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- 閾値 -----------------------------------------------------------------
# **2026-08-08: CLAUDE.md の予算を「行」から「概算トークン + 文字」へ変えた。**
#
#   旧 CLAUDE_MD_MAX=80(行)は、頭の予算 80 行からの**類推**で置いた数字だった。
#   その頭の 80 行自体がどの機構にも存在しない代理指標だったので、根拠の無い数字を
#   根拠の無いまま増やしていたことになる。**代理指標は人が目視で数えるときに要るもので、
#   スクリプトが測るなら実単位で出せる** —— 「ロジックをスクリプトへ寄せる」方針と矛盾していた。
#
#   実測(2026-08-08、配布先4リポジトリの CLAUDE.md):
#     notchbar        70行 / 3,002字 / ≒  768 tok(日本語率  0%)  旧✓ 新✓
#     figmate         88行 / 3,420字 / ≒1,743 tok(日本語率 30%)  旧⚠️ 新✓  ← 誤検知だった
#     swift-mcp-app  109行 / 4,986字 / ≒2,812 tok(日本語率 36%)  旧⚠️ 新⚠️
#     dotfiles       169行 /10,358字 / ≒4,796 tok(日本語率 25%)  旧⚠️ 新⚠️
#   **notchbar と figmate は行数が 1.26 倍しか違わないのに、トークンは 2.27 倍違う。**
#   行は言語構成の関数であって、複数リポジトリへ配る harness にとって最悪の単位。
#   figmate は 88 行というだけで警告されていたが、実費は予算の 87% で健全 —— **行で測っていた
#   ことが生んだ実物の誤検知**。同じ予算が英語なら多くの行を買えるのが正しい挙動。
#
#   CLAUDE.md を縛る実際の機構は2つ:
#     (1) 概算トークン —— **無条件・毎セッション全文ロードされ、compaction 後も disk から
#         再注入される**。つまり払い続ける。これは資源配分であって検知器の閾値ではない
#         (docs/principles.md 規則8)—— 上げるなら実費として意識的に。
#     (2) 文字数 40,000 —— **Claude Code 本体がこの値で警告を出す**(公式)。
#         ハード上限の証拠は無いので ✗ ではなく強い警告として扱う。
#
#   ⚠️ **CLAUDE.md のコストは「毎セッション1回」ではない。乗算される。**
#      CLAUDE.md は**サブエージェントにも継承される**(Explore と Plan だけ例外)。一方で
#      ND の頭を運ぶ SessionStart フックは**サブエージェントでは発火しない**(#46696)。
#        ND の頭   : main のモデルで 1 回
#        CLAUDE.md : 1 + サブエージェント起動回数
#      implementer / artisan / architect を1セッションで回せば CLAUDE.md は4回払う。
#      **2,000 が頭の 3,000 より緩いのは、この構造からすると逆**。ただし実効レバーは
#      閾値ではなく置き場所 —— **main しか要らない情報を CLAUDE.md に置かない**
#      (乗算されるのはこちらだから。手順は skill、ファイル限定の制約は paths 付き rules、
#      現在地は ND の頭へ)。数字を測らずに下げるのは根拠が無いので、まず根拠を正した。
#   ⚠️ 原則3「閾値を上げて警告を消すのは禁止。下げ直すのは可」。
#      単位の是正は「上げ」ではないが、実効が緩む方向のリポジトリが出るのは事実なので隠さない。
# 予算は配布元の正典(plugins/harness/budgets.sh)から読む。**ここには数値を書かない。**
# ⚠️ 読み込みは skip/finish を定義した**後**で行う —— この検査の契約は「必ず exit 0」
#    (`!` 記法で自動実行されるため)。正典が無いときに exit 2 で落ちると契約が壊れる。
#    最初に書いたときは実際に壊していた。**予算を1本化する作業が、別の契約を壊しかけた。**
SECTION_MAX=30                # CLAUDE.md 内の1節がこれを超えたら skill 化を検討(節は人が読む単位なので行が正しい)

# 文字数と概算トークン数。**ロケールに依存させない** —— `wc -m` はロケール次第でバイト数を
# 返す(LANG 未設定の macOS が実際にそう)。代わりに UTF-8 の構造を直接使う:
#   文字数     = 継続バイト(0x80-0xBF)を落とした残りのバイト数(1文字1バイトに潰れる)
#   ASCII 文字 = 0x00-0x7F だけ残したバイト数
# トークンは概算(**英語 ≒ 0.33 tok/字、日本語 ≒ 1.4 tok/字** を混合率で加重)。
#
# **概算しかないのは、Claude Code 自身がローカルトークナイザを持たないから**(2026-08-08 に
# バイナリ 2.1.222 で確認: cl100k / o200k / merges.txt / vocab.json / bpe_ranks すべて 0 件)。
# 本体は `POST /v1/messages/count_tokens` を叩き(**無料**。RPM 制限のみ)、届かなければ
# 文字数だけの概算に落ちて "Token counts are estimates and may differ from actual usage."
# と出す。この式はそのフォールバックと同じ位置(言語で重み付けする分だけ日本語混在では実態に近い)。
#
# ⚠️ **係数は 2026-08-08 に 0.25 / 1.1 から引き上げた。方向を間違えていた。**
#    公式: "Claude 4.7 and later models use a newer tokenizer. The same input text produces
#    **approximately 30 percent more tokens** than on earlier models."
#    0.25 / 1.1 は旧トークナイザの文献値で、**Opus 5 を含む 4.7 以降では約 30% 過小**だった。
#    「日本語 1.1 は過大だから安全側」と書いていたのは誤りで、実際は危険側(予算内に見えて
#    実は超過 = 沈黙する失敗)に倒れていた。× 1.3 して 0.33 / 1.4 にしてある。
#
# ⚠️ **トークナイザはモデルの属性であって、テキストの属性ではない。**同じ文字列でも
#    4.7 未満と 4.7 以降で 30% 違う。スクリプトはセッションのモデルを知れないので、
#    **新しい(=多い)側に固定する** —— 旧モデルでは過大評価になるが、過大は安全側。
#    `mF_=200000` を固定値と読み違えたのと**同じ種類の誤り**(環境依存の値を定数扱いする)。
# ⚠️ まだ実測で較正していない(較正の口は `/context`、または count_tokens API)。
# ⚠️ 概算であることは出力に `≒` で明示する。精密に見えると予算が帳尻合わせに化ける。
# 根拠と較正手順は ../references/context-mechanics.md §4.5。
# Why not python3/tiktoken: tiktoken は **OpenAI の語彙**で Claude とは別物(日本語で大きく
# ズレる)。加えて配布先に python3 がある保証が無く、無いと**黙って計測が消える**(原則4)。
# tr は POSIX で必ずある。この計測は session-start.sh / nd-tasks.sh / survey.sh と同一の式。
# ⚠️ 係数は**上書き可能な既定値**であって定数ではない。harness はエージェント非依存
#    (Codex アダプタを同梱)だが、トークナイザはベンダー固有 —— 文字はテキストそのものの
#    属性、トークンは「テキスト × トークナイザ」の属性。定数として埋めると他クライアントで
#    黙って嘘になるので env で差し替えられるようにし、出力にラベルを出す。
TOK_ASCII_PCT=${HARNESS_TOK_ASCII_PCT:-33}
TOK_WIDE_PCT=${HARNESS_TOK_WIDE_PCT:-140}
TOKENIZER_LABEL=${HARNESS_TOKENIZER_LABEL:-Claude 4.7+}
measure_file() {
  MEAS_CHARS=$(LC_ALL=C tr -d '\200-\277' < "$1" | wc -c | tr -d ' ')
  local ascii; ascii=$(LC_ALL=C tr -cd '\000-\177' < "$1" | wc -c | tr -d ' ')
  MEAS_TOKENS=$(( (ascii * TOK_ASCII_PCT + (MEAS_CHARS - ascii) * TOK_WIDE_PCT) / 100 ))
}
findings=0

note() { printf '  %s\n' "$*"; }
warn() { printf '  ⚠️ %s\n' "$*"; findings=$((findings+1)); }
bad()  { printf '  ✗ %s\n' "$*"; findings=$((findings+1)); }
ok()   { printf '  ✓ %s\n' "$*"; }
# skip: 「前提が欠けて検査できなかった」専用。⚠️/✗/✓ と見分けが付く ⏭ を使う。
# findings に数えるのは意図的 —— ここを note 相当(無カウント)にすると「指摘0件」に
# 埋もれ、原則4「0件は壊れたを疑う」が機能しなくなる。メッセージには必ず
# 「何が無くて検査できなかったか」を書くこと(次に何をすれば直るかが分かる形)。
skip() { printf '  ⏭ %s\n' "$*"; findings=$((findings+1)); }

# finish: 出力の最後に完走マーカーを1行出してから exit 0 する共通の出口。
# Why not 個々の exit 0 のままにしないのか: マーカーを出す場所が複数箇所に分散すると
# 書式が揃わなくなる/出し忘れる箇所ができる(実際に旧実装は `cd "$root" || exit 0` の
# ようにマーカー無しの出口が複数あった)。**完走マーカーは「途中で死んでいないか」を
# 出力だけで判定するための唯一の手がかり**なので、出口を1関数に集約して出し忘れを防ぐ。
finish() {
  echo
  if [ "$findings" -eq 0 ]; then
    echo "指摘なし。"
  else
    echo "指摘 ${findings} 件。各指摘の意味と直し方はこの skill の本文を参照。"
  fi
  echo "=== 検査完了: ${findings} 件(check.sh v0.11.0) ==="
  exit 0
}

# --- 前提: 予算の正典 -----------------------------------------------------
BUDGETS="$(cd "$(dirname "$0")/../../.." && pwd)/budgets.sh"
if [ -r "$BUDGETS" ]; then
  # shellcheck source=/dev/null
  . "$BUDGETS"
else
  # 黙って既定値へ落ちない —— 落ちると「検査した結果 OK」と区別が付かなくなる(原則4)。
  echo "=== harness:doctor ==="
  skip "予算の正典が読めない($BUDGETS)。プラグインが壊れているか、スクリプトだけを取り出して実行している"
  finish
fi

# --- 前提: git -----------------------------------------------------------
# 以降ほぼ全ての節(rules の paths 判定・個人設定分離・セッション引き継ぎハーネス・
# pre-push・skills の一部)が `git ls-files` / `git log` / `git config` の結果を土台に
# している。旧実装は `git rev-parse --show-toplevel 2>/dev/null || pwd` で非リポジトリ時に
# 黙って pwd へフォールバックしていたが、それだと後続の git 系コマンドが軒並み空振りし、
# 「rules の paths がどのファイルにもマッチしない = ✗」のような**誤った致命判定**が
# 積み上がる(paths 自体は正しいのに、単に git ls-files が動いていないだけ)。
# ボツ案: git コマンドごとに個別 guard を挟む。→ 分散させると一部だけ壊れた中途半端な
# 出力になり、「どこまでが信用できる出力か」が読み手に伝わらない。土台が壊れているなら
# 検査全体を諦めて ⏭ 1件を出し切り上げるほうが、原則4「0件は壊れたを疑う」に忠実。
if ! command -v git >/dev/null 2>&1; then
  echo "=== harness:doctor ==="
  skip "git コマンドが見つからない。この検査は git 依存のため実行できなかった(PATH を確認すること)"
  finish
fi
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "=== harness:doctor ==="
  skip "git リポジトリの外(または壊れたリポジトリ)なので実行できなかった。git リポジトリのルートで実行すること"
  finish
fi
root=$(git rev-parse --show-toplevel)
cd "$root" || { skip "リポジトリのルート ($root) へ移動できなかった"; finish; }
echo "=== harness:doctor — $(basename "$root") ==="

# --- CLAUDE.md ---------------------------------------------------------------
echo
echo "## CLAUDE.md(常時ロード = 全行が毎セッションのコスト)"
if [ ! -e CLAUDE.md ]; then
  warn "CLAUDE.md が無い(プロジェクトの基盤情報が毎回ゼロから推測される)"
elif [ ! -r CLAUDE.md ]; then
  # 権限で読めないファイルを「無い」扱いにすると存在しないと誤って伝わり、逆に
  # 中身をそのまま読もうとすると wc/grep が空文字を返して「0行=ok」のような
  # 誤った良好判定に化ける(旧実装はここが素通りだった)。読めない、と正直に言う。
  skip "CLAUDE.md の読み取り権限が無く検査できなかった"
else
  lines=$(wc -l < CLAUDE.md | tr -d ' ')
  measure_file CLAUDE.md
  # 行数も出すが**予算としては出さない**(参考値)。行はどの機構も使っておらず日本語率で
  # 2倍以上ブレるが、人が「どこを削るか」を探すときの手掛かりは結局行なので表示は残す。
  if [ "$MEAS_CHARS" -gt "$CLAUDE_MD_HARD_CHARS" ]; then
    warn "CLAUDE.md が ${MEAS_CHARS} 字(Claude Code 本体が ${CLAUDE_MD_HARD_CHARS} 字で警告を出す)。≒${MEAS_TOKENS} tok / ${lines} 行 — 手順は skill、ファイル限定の制約は paths 付き rules へ"
  elif [ "$MEAS_TOKENS" -gt "$CLAUDE_MD_WARN_TOKENS" ]; then
    warn "CLAUDE.md が ≒${MEAS_TOKENS} tok(${TOKENIZER_LABEL} 換算・予算 ${CLAUDE_MD_WARN_TOKENS} tok。${MEAS_CHARS} 字 / ${lines} 行)。**無条件・毎セッション全文ロードされ compaction 後も再注入される**ので、太った分をずっと払い続ける — 手順は skill、ファイル限定の制約は paths 付き rules へ"
  else
    ok "CLAUDE.md ≒${MEAS_TOKENS} tok(${TOKENIZER_LABEL} 換算・予算 ${CLAUDE_MD_WARN_TOKENS} tok。${MEAS_CHARS} 字 / ${lines} 行)"
  fi
  # 「毎回X したら Y」= 指示は必ず守られるとは限らない → Hook が正解(記事のアンチパターン)。
  if grep -nE '毎回|必ず[^。]*(実行|走ら|チェック)|する前に必ず|常に.*(実行|確認)' CLAUDE.md >/dev/null 2>&1; then
    warn "CLAUDE.md に「毎回/必ず〜する」系の自動化指示がある。指示は守られないことがあるので Hook(決定論的)へ移すのが正解:"
    grep -nE '毎回|必ず[^。]*(実行|走ら|チェック)|する前に必ず|常に.*(実行|確認)' CLAUDE.md | head -3 | sed 's/^/       /'
  fi
  # 「絶対に〜するな」= 長いセッションで破綻しうる → permissions/hooks で強制するのが正解。
  # ただし「コードから絶対に読み取れない」のような**可能表現**は禁止指示ではない。
  # 2026-08-05 に cf-asc-dashbord の CLAUDE.md(コメント方針の説明文)で誤検知したため、
  # 可能形(読み取れ/分から/でき/見え/得られ)が続く場合は除外する。
  prohibit_re='絶対に[^。]*(な|禁止)|してはいけない|してはならない|しないこと'
  capability_re='絶対に[^。]*(読み取れ|分から|でき|見え|得られ|判断でき)'
  if grep -nE "$prohibit_re" CLAUDE.md 2>/dev/null | grep -vE "$capability_re" | head -1 | grep -q .; then
    warn "CLAUDE.md に強い禁止指示がある。サーバー側(permissions / PreToolUse hook)で止める方が確実:"
    grep -nE "$prohibit_re" CLAUDE.md | grep -vE "$capability_re" | head -3 | sed 's/^/       /'
  fi
  # 長い手順が埋まっていないか(節ごとの行数)。
  awk '/^## /{if(name && n>'"$SECTION_MAX"') print "       " name " (" n " 行)"; name=$0; n=0; next} {n++} END{if(name && n>'"$SECTION_MAX"') print "       " name " (" n " 行)"}' CLAUDE.md > /tmp/.doctor_sections 2>/dev/null
  if [ -s /tmp/.doctor_sections ]; then
    warn "CLAUDE.md に長い節がある(${SECTION_MAX} 行超)。手順なら skill へ移すと常時コストが消える:"
    cat /tmp/.doctor_sections
  fi
  rm -f /tmp/.doctor_sections
fi

# --- rules -------------------------------------------------------------------
echo
echo "## .claude/rules(paths 付きなら該当ファイル操作時のみロード)"
if [ ! -d .claude/rules ]; then
  note "rules 無し"
else
  for f in .claude/rules/*.md; do
    [ -e "$f" ] || continue
    if [ ! -r "$f" ]; then
      # 読めないファイルを `head -1 | grep -q '^---'` にそのまま通すと、grep が
      # 空入力で「マッチしない」を返し「frontmatter が無い」という**間違った**指摘に
      # 化ける(実際は「有るかどうか読めていない」のに)。読めない、を先に言う。
      skip "$(basename "$f"): 読み取り権限が無く検査できなかった"
      continue
    fi
    if ! head -1 "$f" | grep -q '^---'; then
      warn "$(basename "$f"): frontmatter が無い = 常時ロード。paths を付けると無関係な作業でのコストが消える"
      continue
    fi
    if ! awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f' "$f" | grep -q '^paths:'; then
      warn "$(basename "$f"): paths: が無い = 常時ロード"
      continue
    fi
    # ⚠️ 最重要: glob が1つも実ファイルにマッチしないと silent に無効化される
    #    (swift-mcp-app で 2026-07-22 に実際に起きた。CLAUDE.md は「自動ロード」と
    #     書いてあったのに、TypeScript 用の src/** を Swift リポへ持ち込んで死んでいた)。
    globs=$(awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f' "$f" | awk '/^paths:/{p=1;next} p&&/^[a-zA-Z]/{exit} p' | grep -oE '"[^"]+"' | tr -d '"')
    matched=0
    for g in $globs; do
      # ** を含む glob は git ls-files のパターンで概ね評価できる
      if git ls-files -- "$g" 2>/dev/null | head -1 | grep -q .; then matched=1; break; fi
    done
    if [ "$matched" -eq 1 ]; then
      ok "$(basename "$f"): paths 有効(マッチするファイルあり)"
    else
      bad "$(basename "$f"): paths がどのファイルにもマッチしない = 一度もロードされない。glob をこのリポジトリの構成に合わせること: $(echo "$globs" | tr '\n' ' ')"
    fi
  done
fi

# --- 個人設定の混入 -----------------------------------------------------------
echo
echo "## 個人環境の分離"
if git ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
  bad ".claude/settings.local.json が git 追跡されている(個人の permission が共有される)。git rm --cached で外すこと"
elif grep -qs 'settings.local.json' .gitignore; then
  ok ".claude/settings.local.json は gitignore 済み"
else
  warn ".gitignore に .claude/settings.local.json が無い(生成されるとコミットされうる)"
fi

# --- ハーネス本体 -------------------------------------------------------------
echo
echo "## セッション引き継ぎハーネス"
nd=""
for cand in docs/next-directions.md docs/*/next-directions.md; do
  [ -f "$cand" ] && { nd="$cand"; break; }
done
if [ -z "$nd" ]; then
  warn "next-directions.md が無い(セッション間の引き継ぎが会話履歴頼みになる)。/harness:doctor で導入できる"
else
  ok "正典: $nd"
  if grep -q '^<!-- session-head-end' "$nd"; then
    # ⚠️ **ここで頭のサイズを測らないのは意図的**(2026-08-08 に削除)。
    # 旧実装は「頭が N 行(目安 80)」を出していたが、頭のサイズはこの時点で
    # **3箇所が3つの単位で測っていた** —— session-start.sh が行、nd-tasks.sh がバイトと行、
    # ここが行(しかも 80 をハードコード)。原則7「正典は1箇所」に正面から反する。
    # 正典は assets/session-start.sh(注入の当事者・毎セッション走る)、横断の一覧は
    # /harness:status。doctor の仕事は**構造が壊れていないか**(マーカーの有無)であって、
    # サイズの再計測ではない。数字が要るときは status を叩く。
    ok "session-head-end マーカーあり(頭のサイズは /harness:status が出す)"
  else
    # pointer 方式(マーケットプレイス型)なら頭注入しないのでマーカーは不要。
    if grep -qs 'next-directions' .claude/hooks/session-start.sh 2>/dev/null; then
      note "マーカー無し(pointer 方式のフックなら正常)"
    else
      warn "$nd に session-head-end マーカーが無い(頭注入型フックでは fail-closed で止まる)"
    fi
  fi
  # 鮮度: 現在地の日付より新しいコミットがあるか。
  # ⚠️ 旧実装は**ファイル全文から最初の日付**を拾っていた。動いてはいたが、頭の本文に
  #    日付(更新ブロックなど)が現在地の見出しより前に来ると別の日付を読む。
  #    session-start.sh(v0.3.0)と同じく**見出し行を特定してからその行の日付を拾う**形に揃えた
  #    —— 同じ検査が2実装で違う答えを出す状態を残さない。
  hl=$(grep -m1 -E '^#+[[:space:]]*現在地' "$nd" || true)
  hd=$(printf '%s' "$hl" | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)
  lc=$(git log -1 --format=%cs 2>/dev/null)
  # 見出しはあるのに日付が取れない = 鮮度検査が無効化されている。黙って通さない(原則4)。
  if [ -z "$hl" ]; then
    warn "$nd に \`## 現在地\` の見出しが無い(鮮度検査が無効化されている)"
  elif [ -z "$hd" ]; then
    warn "現在地の見出しから日付が読めない(鮮度検査が無効化されている): $hl"
  elif [ -n "$lc" ] && [ "$lc" \> "$hd" ]; then
    warn "正典の日付($hd)より新しいコミット($lc)がある = 更新漏れの可能性"
  fi
fi
[ -e .claude/hooks/session-start.sh ] && ok "SessionStart フックあり" || warn "SessionStart フックが無い(正典が自動で思い出されない)"

# --- pre-push(H-10・2026-08-07 修正) -----------------------------------------
# ⚠️ Why not 「.githooks/pre-push の有無」を起点にしない: 旧実装はここが起点で、無ければ
#    即「pre-push が無い」と判定していた。**git 自身が pre-push をどこから読むかは
#    core.hooksPath で決まる**のに、起点をこのハーネスの配布物の置き場所(.githooks/)に
#    固定していたのが誤り。実例: dotfiles は `core.hooksPath=git/hooks` で運用しており
#    `git/hooks/pre-push` が実在して正しく動いているのに、`.githooks/pre-push` が無いという
#    理由だけで「pre-push が無い」と誤検知していた(2026-08-07 実測)。
#    あるべき形は git の設定を起点にすること: core.hooksPath があればそのディレクトリ、
#    無ければ git の既定(.git/hooks。ただし submodule / worktree では GIT_DIR が repo 直下の
#    .git ではないことがあるので `git rev-parse --git-path hooks` で正しく解決する)。
hp=$(git config --get core.hooksPath 2>/dev/null || true)
if [ -n "$hp" ]; then
  hookdir="$hp"                                                    # 相対でも絶対でも git はそのまま使う
else
  hookdir=$(git rev-parse --git-path hooks 2>/dev/null || printf '.git/hooks')
fi
active_pp="$hookdir/pre-push"

# .githooks/pre-push は「harness がここに置く配布物」の場所であって、git が実際に読む場所
# とは限らない。**「置いたのに配線し忘れている」は本物の壊れ方なので個別に先に判定し残す**
# (install.sh がここへ配置したのに core.hooksPath を向け忘れているケースが実在する。
#  H-1 の完了記録を参照)。ここを先に分岐させて一般判定と統合しないのは、二重報告
# (「pre-push が無い」+「.githooks/pre-push はあるが…」)を避けるため。
if [ -x .githooks/pre-push ] && [ -z "$hp" ]; then
  bad ".githooks/pre-push はあるが core.hooksPath 未設定 = 動いていない。git config core.hooksPath .githooks"
elif [ -x .githooks/pre-push ] && [ -n "$hp" ]; then
  # core.hooksPath は相対(.githooks)でも絶対(/path/to/repo/.githooks)でも設定できる。
  # 文字列一致で見ると絶対パス設定を「未配線」と誤検知するので、末尾で判定する。
  case "$hp" in
    .githooks|*/.githooks)
      if grep -qs 'harness-template v' .githooks/pre-push; then
        ok "pre-push 配線済み(harness-template)"
      else
        # 刻印(harness-template vX.Y.Z)が無い pre-push を harness 製と決めつけない。
        # 他人の文化を侵さないのがこのハーネスの方針 —— warn ではなく note(情報)に留める。
        note "pre-push はあるが harness 製ではない(.githooks 配下・刻印なし)"
      fi
      ;;
    *) warn ".githooks/pre-push はあるが core.hooksPath が別の場所($hp)を指している" ;;
  esac
elif [ -x "$active_pp" ]; then
  # ここに来るのは .githooks/pre-push が無いケース = core.hooksPath が指す先に
  # 別の pre-push が実在する(dotfiles の git/hooks/pre-push のような運用)。
  if grep -qs 'harness-template v' "$active_pp"; then
    ok "pre-push 配線済み(harness-template。hooksPath: ${hp:-既定 .git/hooks})"
  else
    # 「harness 製か」は刻印で判定する。刻印が無ければ他人の pre-push を尊重し、
    # 警告でも良好でもなく事実だけを伝える(置き換えの提案はしない)。
    note "pre-push はあるが harness 製ではない(hooksPath: ${hp:-既定 .git/hooks})。既存の運用を尊重する"
  fi
else
  warn "pre-push が無い(壊れたコードが main へ push されうる)"
fi

# --- skills ------------------------------------------------------------------
echo
echo "## skills"
# description 長の判定は python3 の YAML パースもどきに依存している(下記)。
# 無い環境(最小構成のコンテナ等)では従来 `python3 -c ... || echo 0` が黙って
# desc_len=0 を返し、「description が無い」という**間違った**指摘に化けていた
# ("description は書いてあるのに python3 が無いだけ" を区別できなかった実例)。
# ループの中で毎回 command -v するのは無駄なので、ここで1回だけ判定して使い回す。
has_python3=1
command -v python3 >/dev/null 2>&1 || has_python3=0
[ "$has_python3" -eq 1 ] || skip "python3 が無いため skill の description 長を検査できなかった(該当する全 skill が対象外。以下は名前/frontmatter/scripts 実行権限のみ検査する)"
found_skill=0
for s in .claude/skills/*/SKILL.md plugins/*/skills/*/SKILL.md; do
  [ -e "$s" ] || continue
  found_skill=1
  d=$(dirname "$s"); n=$(basename "$d")
  if [ ! -r "$s" ]; then
    skip "$n: SKILL.md の読み取り権限が無く検査できなかった"
    continue
  fi
  head -1 "$s" | grep -q '^---' || { bad "$n: frontmatter が無い"; continue; }
  fm=$(awk 'NR==1&&/^---/{g=1;next} g&&/^---/{exit} g' "$s")
  echo "$fm" | grep -q '^name:' || warn "$n: name が無い"
  # description は YAML の折り畳みスカラー(`description: >-` + 字下げ続き行)で書かれることが
  # 多い。1行目だけ見ると空に見えて「短い」と誤検知するので、続き行も連結して測る。
  if [ "$has_python3" -eq 0 ]; then
    note "$n: description 長は python3 が無いため未検査(上記の ⏭ を参照)"
  else
    desc_len=$(printf '%s' "$fm" | python3 -c '
import sys
lines = sys.stdin.read().split("\n")
out, capture = [], False
for ln in lines:
    if ln.startswith("description:"):
        rest = ln[len("description:"):].strip()
        if rest in (">", ">-", "|", "|-"):
            capture = True
        else:
            out.append(rest)
        continue
    if capture:
        if ln.startswith((" ", "\t")):
            out.append(ln.strip())
        else:
            capture = False
print(len(" ".join(out).strip()))
' 2>/dev/null || echo 0)
    if [ "${desc_len:-0}" -eq 0 ]; then
      warn "$n: description が無い(自動トリガーされない)"; continue
    fi
    [ "$desc_len" -lt 40 ] && warn "$n: description が ${desc_len} 字と短い。いつ使うかが書かれていないと自動で呼ばれない"
  fi
  # scripts があるなら実行可能か(chmod 忘れは頻出)
  for sc in "$d"/scripts/*.sh; do
    [ -e "$sc" ] || continue
    [ -x "$sc" ] || bad "$n: $(basename "$sc") に実行権限が無い"
  done
done
[ "$found_skill" -eq 1 ] || note "skill 無し"

finish
