#!/usr/bin/env bash
# harness-template v0.2.0 (配布元: gigun-dev/claude-code plugins/harness)
#   — 着手順ボード(2カラムの高密度 HTML)を nd-tasks.sh の JSON から**決定論的に**生成する。
#
# 【なぜスクリプト化するか(原則3: 予算を先に置くと規律が要らなくなる)】
#   このボードは 2026-08-09〜10 の間、エージェントがその場で HTML を書いて作っていた。
#   つまり **再生成のたびに CSS もレイアウトも書き直させていた** —— 出力は毎回微妙に違い、
#   トークンも毎回払う。テンプレートは資産であって推論の対象ではないので、ここへ固定して
#   「更新 = データの差し込み」だけにする。**以後この HTML の再生成にモデルは一切関与しない。**
#   (公式 agentskills.io のスクリプト化基準「一発で正しく書けないほど複雑」
#    「毎回同じロジックを再発明している」の後者にそのまま当たる。)
#
#   ⚠️ **テンプレートはこのファイルの中に埋め込む。**assets/board.html のように分けると
#   配布物が2本になり、「片方だけ古い」を作れてしまう(原則7: 複製すれば必ずドリフトする)。
#   スクリプト1本で完結する限り、その壊れ方は構造的に起きない。
#
# 【出口の設計 —— なぜ既定が .git 配下か】
#   既定の出力先は `$(git rev-parse --absolute-git-dir)/harness-board.html`。
#   - `.git/` の中なので **git は最初から見ない** —— .gitignore に1行足す必要すら無い
#     (nd-tasks.sh のロックが .gitignore を要らなくしたのと同じ判断)。
#   - リポジトリごとに1枚。worktree では worktree 側の gitdir に出るので、
#     並行作業のボードが互いを踏まない。
#   - `-o <path>` で明示指定できる。Artifact として人へ渡すとき / CI が成果物として
#     拾うときはこちら(出力先を1つに縛ると、その用途が全部「既定を上書きするハック」になる)。
#   - **将来 post-commit hook から呼ぶ**(コミットのたびにボードが最新になる)。
#     ⚠️ hook の配線は H-28(pre-commit)がマージされて .githooks/ の形が決まってから。
#     ここでは「呼ばれても壊れない」ことだけ守る = 副作用は出力ファイル1本、stdout はパスのみ。
#
# 【出力の契約】
#   stdout  … 書き出したパス1行だけ。`open "$(render-board.sh)"` がそのまま動く。
#   stderr  … 警告・診断。**黙って落とさない**(原則4)。所在バッジの git 失敗もここへ出る。
#   終了コード 0 = 書けた / 2 = 使い方の誤り・出力先が決められない / 上流(nd-tasks)の致命エラーはそのまま伝播。
#
# 【依存辺が「自由文パース」である理由と、H-15 後の差し替え点】
#   正典(next-directions.md)は依存を機械可読には持っていない。現状あるのは項目本文の
#   `依存: H-7` のような**散文の言及だけ**。ここでは正規表現で拾う —— 汚いが、
#   「依存を書くための新しい書式」を先に作るより、**既にある書き方から読める分だけ読む**方が
#   原則6(新機構を足す前に既存機構で届くか見る)に合う。
#   ⚠️ 抽出は python 側の `extract_edges()` **1関数に隔離してある。**H-15(着手順に依存辺を
#      足す)が入って JSON に構造化フィールドが生えたら、**差し替えるのはあの関数だけ**で、
#      blocked 判定・focus ビュー・タイルは1行も触らない。
#
# 【--branches が「対応表を持たない」設計であること】
#   「どの ID をどのブランチでやっているか」の表は**作らない。**git 履歴が既にその
#   データベースだからで、足りないのは保存ではなく**到達性**(原則6)。だから毎回引き直す。
#   表を持つと必ず腐る(ブランチを消しても表は残る)し、更新の規律が人間に戻ってくる。
#   ⚠️ **既定 OFF。** 理由は2つ: (1) git の呼び出しぶんだけ確実に遅くなる、
#      (2) 精度が「コミットメッセージに ID を書く」という**運用の規律に依存する**ので、
#      本体(着手順・依存・blocked)と同じ信頼度で並べるべきではない。強化機能は
#      強化機能の顔をしていること。
#
# 【なぜ mermaid ではないか(ボツ案)】
#   最初の版はグラフを mermaid で描いた。**一覧性が死ぬ**のを実測した ——
#   29項目のノードは画面に収まらず、順序(この repo の依存の実体は「位置」)が消える。
#   構造の実体は「コンポーネント → 順序付きリスト」の2層であって木ではないので、
#   **表現も2カラムのリスト**が正しい。グラフが要るのは1項目の近傍だけで、それは
#   focus ビュー(クリックで上流/下流を出す)で足りる。**全域グラフは描かない。**
#
# =============================================================================
# 【v0.2.0 で変えた5点 —— ユーザーレビュー(2026-08-10)への回答】
# =============================================================================
# v0.1.0 は「データは全部出ているのに、読み手が判断できない」形で5箇所詰まっていた。
# どれも**情報を足す**のではなく、**既にある情報の見せ方**を直している(新しいデータ源は
# 1つも増やしていない —— 原則6: 足りないのは保存ではなく到達性)。
#
# (1) 宙吊り辺の解決を「完了記録」まで広げた。
#     v0.1.0 は「着手順に居ない ID」を全部 **⇐(参照先なし)**にしていたので、実際には
#     終わっている H-3 / H-28 が「行方不明」に見えていた。**ND 全文は現在地の抽出で
#     既に読んでいる**ので、`## 完了記録` 側の ID も同じ読み込みから拾う —— 新しい I/O も
#     新しい書式も要らない。結果は3値になった:
#       ⇠ X 待ち … X は着手順にいて未完了(= blocked。行が淡くなる)
#       ⇐ X ✔    … X は完了記録にある(淡色。完了日が拾えれば title に出す)
#       ⇐ X      … **ファイル全体のどこにも無い**(ここで初めて「参照先なし」を名乗る)
#     ⚠️ アーカイブ判定は**節の名前ではなく行の書式**で行う(`- ~~`ID`~~`)。見出し名
#        (「完了記録」)に依存させると、配布先が節名を変えた瞬間に**黙って 0 件**になる。
#        書式そのものが「これは取り下げ済みだ」という意味を運んでいるので、そちらを読む。
#        0 件になったのがパーサの死かどうかを見分けるため、「`- ~~` で始まる行はあるのに
#        ID が1つも取れなかった」ときだけ stderr で鳴らす(原則4)。
#
# (2) `<details>` を全廃した。
#     **隠すべきでない情報を既定で畳むのはダークパターン**、というユーザー指摘をそのまま採る。
#     畳んであったのは「現在地」(= 未検証の危険・裁定待ちが書いてある場所)と
#     カタログ目次で、**どちらもボードを開いた人が最初に見るべきもの**だった。
#     副作用として click による高さジャンプ(開閉のたびに下のボードが飛ぶ)も消えた。
#     ⚠️ ボツ案: 「現在地だけ open 属性を付ける」。畳む機構が残る限り、次に情報が増えたとき
#        「とりあえず details に入れる」が再発する。**機構ごと消す**方が構造的に強い。
#
# (3) 頭サイズを「N件 超過」からミニ棒グラフ2本にした。
#     「2件 超過」は**予算に対する現状**を1文字も伝えていない(8,001字なのか 30,000字なのか
#     区別できない)。ND ファイルごとに文字/トークンの2本を描き、警告(8,000字・3,000tok)と
#     **切り詰め(10,000字)の位置に縦マーカー**を立てる —— 「あと何文字で無言切り詰めか」は
#     この harness が最も気にしている距離なので、そこが目盛りとして見えていること。
#     ⚠️ 目盛りは**全ボードで共通**にしてある。ボードごとに正規化すると、8,934字と 3,825字の
#        バーが同じ長さになり、比較という棒グラフ唯一の取り柄が消える。
#     ⚠️ 予算値は budgets.sh から。ここに数値は書かない(v0.1.0 と同じ理由。原則7)。
#
# (4) 「次(<コンポーネント>)」タイルを消した。
#     ■ が各ボードの先頭で同じことを言っている —— **同じ事実の2箇所目**は原則7 が禁じている
#     形(ドリフトはしないが、画面の面積という有限資源を重複に使っている)。
#     タイル行は「未完了/完了」と「依存辺」だけになった(頭サイズは (3) のバーへ吸収)。
#
# (5) 依存辺を `git log --oneline --graph` 方式の**文字のレール**で描いた。
#     バッジ(⇐ / ⇠)は「誰に依存しているか」を名指しするが、**構造**(どこからどこへ跨いで
#     いるか)は読めない。行の右端に mono の罫線列を足し、上流の行から下流の行へ線を引く。
#     ⚠️ **SVG のピクセル計算は採らない。**行高はフォント・ズーム・言語・テーマで変わるので、
#        座標を計算した瞬間に「環境が変われば線がズレる」という直せない壊れ方を抱える。
#        文字で描けば**行揃えはブラウザの行組みがやる**のでズレようがなく、色も文字色
#        (テーマトークン)にそのまま乗る。
#        ⚠️ ただし文字にも1つだけ数値の調整が残る: **行の高さと罫線字形の高さを合わせる**
#           (合わないと縦線が鎖に見える)。テンプレートの `.rail` に算出根拠を書いてある。
#           **合わせ方を間違えても線が太る/薄れるだけで、位置はズレない** —— これが
#           ピクセル計算との決定的な差で、壊れ方の最悪値が違う。
#     ⚠️ レールは**行の右端**に置く(バッジより後ろ)。真ん中に置くと、左のバッジの幅が
#        行ごとに違うぶんレール列の x 位置が行ごとにズレて、縦線が繋がらない。端に置けば
#        どの行でも右端から同じ幅なので、**内容に関係なく必ず揃う**。
#        (git log --graph はレールを左端に置く。どちらの端でも揃うが、ここでは
#         「■ / ID / 本文」という既存の読み順を壊さない右端を採った。)
#     ⚠️ アーカイブ済みへの辺はレールに描かない —— **相手の行がボードに無い**ので、線の
#        終点が存在しない。そこはバッジ(⇐ H-3 ✔)の担当。レール = 構造、バッジ = 名指し、
#        で役割を分けてある(**抽出は同じ extract_edges() 1本**。二重実装ではない)。
#
# 【依存(新規に増やさない)】
#   bash + python3 + git。python3 は verify.sh・doctor が既に必須にしているので追加負担は無い。
#   ⚠️ python3 が無い環境では**黙って劣化させず落とす**(原則4。「検査できなかった」を
#      「合格」にしないのと同じで、「描けなかった」を「空のボード」にしない)。
set -euo pipefail

VERSION="0.2.0"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
NDTASKS="$SELF_DIR/nd-tasks.sh"
# 予算の正典は plugins/harness/budgets.sh。**ここには数値を書かない**(nd-tasks.sh と同じ理由 ——
# 同じ閾値が2箇所にあると必ず片方だけ動く。実際に単位の読み違いが5箇所へ伝播した前科がある)。
BUDGETS="$(cd "$SELF_DIR/../../.." && pwd)/budgets.sh"

usage() {
  cat <<'EOF'
使い方: render-board.sh [options] [<next-directions.md> ...]

正典の「着手順」を**着手順ボード**(2カラムの高密度 HTML)として1枚書き出す。
データ源は同じディレクトリの nd-tasks.sh --format json で、このスクリプトは
**描画だけ**を行う(正典は next-directions.md のまま。中間ファイルは作らない)。

オプション:
  -o <path>     出力先。既定は $(git rev-parse --absolute-git-dir)/harness-board.html
                (.git 配下なので git は最初から見ない = .gitignore が要らない)。
  --branches    open な各 ID について「まだ main に載っていないコミットで、その ID に
                言及しているブランチ」を引き、行末に ⎇ バッジで出す。**既定 OFF**
                (git 呼び出しぶん遅くなる / 精度がコミットメッセージの規律に依存する)。
                基準ブランチは origin/HEAD → main → master の順に自動判定。
                HARNESS_BOARD_BASE=<branch> で上書きできる。
  -h, --help    これ。
  <path> ...    走査する ND を明示する(nd-tasks.sh へそのまま渡る。書式検証用)。

出力:
  stdout に書き出したパスを1行だけ出す。`open "$(render-board.sh)"` がそのまま動く。
  警告・診断は stderr。

ボードの読み方:
  ■ = 次(そのコンポーネントで blocked でない最初の未完了)
  ☐ = 未完了(上から着手順)   ✔ = 完了
  ⇠ X 待ち = X(未完了)に依存していて着手できない —— 行が淡くなる
  ⇐ X ✔    = X に依存。X は「完了記録」にある(= 済んでいる)。blocked には数えない
  ⇐ X      = X に依存と書かれているが、X は ND のどこにも無い(散文中の例 or 書き間違い)
  ⎇ name   = --branches 指定時のみ。その ID に言及する未マージのコミットがあるブランチ
  行の右端のレール(●─╮ │ ●─╯)= 依存辺。上流の行から下流の行へ。同じボード内のみ描く
             (アーカイブ済みへの辺は終点の行が無いのでバッジだけ)。
  頭サイズのバー = ND の頭。縦線が予算(文字は警告と切り詰めの2本、トークンは1本)。
             目盛りは全ボード共通なので、ボード同士を長さで比較できる。
  行をクリック = focus。上流(これを塞いでいるもの)と下流(これが解けると動くもの)を
             推移的に出す。もう一度クリック / Esc / ✕ で解除。全域グラフは描かない。
  「現在地」とカタログ目次は各ボードの下に**常時表示**(v0.2.0 で <details> を全廃した ——
  未検証の危険や裁定待ちが書いてある場所を既定で畳むべきではない)。

終了コード:
  0  書き出した
  2  使い方の誤り / 出力先が決められない / python3 が無い
  それ以外は nd-tasks.sh の終了コードをそのまま返す(正典が読めない = 描けない)
EOF
}

# --- 引数 ---------------------------------------------------------------------
OUT=""
WANT_BRANCHES=0
EXPLICIT=()

# 値を取るフラグの「値が無い / 値がフラグに見える」を先に潰す(nd-tasks.sh と同じ流儀)。
# 空文字のまま進むと「出力先が空で python が謎のエラーを出す」という**分かりにくい失敗**になる。
need_val() {
  case "${2-__MISSING__}" in
    __MISSING__) echo "✗ $1 には値が要る(例: $3)。" >&2; exit 2 ;;
    -*)          echo "✗ $1 の値がフラグに見える: $2(例: $3)。" >&2; exit 2 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) need_val -o "${2-__MISSING__}" '-o /tmp/board.html'; OUT="$2"; shift 2 ;;
    --branches)  WANT_BRANCHES=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "不明な引数: $1" >&2; usage >&2; exit 2 ;;
    *)           EXPLICIT+=("$1"); shift ;;
  esac
done

command -v python3 >/dev/null 2>&1 || {
  # 黙って劣化させない。「描けなかった」を「空のボード」として出すと、
  # 見た人は「タスクが無い」と読む —— この repo が最も嫌う壊れ方(原則4)。
  echo "✗ python3 が見つからない — ボードを描画できない(空の HTML は出さない)。" >&2
  exit 2
}
[ -r "$NDTASKS" ] || {
  echo "✗ データ源が見つからない: $NDTASKS(status skill の配置が壊れている可能性)" >&2
  exit 2
}
# shellcheck source=/dev/null
[ -r "$BUDGETS" ] || { echo "✗ 予算の正典が読めない: $BUDGETS" >&2; exit 2; }
. "$BUDGETS"

# --- 出力先の決定 -------------------------------------------------------------
if [ -z "$OUT" ]; then
  # --absolute-git-dir を使うのは、worktree でもサブディレクトリからでも同じ答えになるから
  # (--git-dir は相対パスを返すことがあり、python 側の cwd と食い違う)。
  GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
  [ -n "$GITDIR" ] || {
    echo "✗ git リポジトリの外なので既定の出力先が決められない。-o <path> で指定すること。" >&2
    exit 2
  }
  OUT="$GITDIR/harness-board.html"
fi
OUT_DIR="$(dirname "$OUT")"
[ -d "$OUT_DIR" ] || { echo "✗ 出力先のディレクトリが無い: $OUT_DIR" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/render-board.XXXXXX")
trap 'rm -rf "$tmp" 2>/dev/null || true' EXIT INT TERM
# PIPE ⚠️ ここは書き込みを行うが、書き込みは python 側の「一時ファイル + os.replace」で
#    閉じている(このシェルはロックも中間状態も持たない)ので、握りつぶさず単に後始末して抜ける。
trap 'rm -rf "$tmp" 2>/dev/null || true; exit 141' PIPE

# --- データ源(nd-tasks.sh --format json) --------------------------------------
# rc の扱い: **違反(rc=1)でも描く。**JSON 自体は完全に出ているし、「書式違反があるから
# ボードを出さない」は困っている人から地図を取り上げる動作になる。ただし stderr は
# そのまま素通しして、違反の存在を隠さない(原則5: 強制は最小、検知は最大)。
# rc>=2 は「走査対象が無い / 正典が読めない」= 描くものが無いので、そのまま伝播させる。
# `bash "$NDTASKS"` と明示的に起動する(直接実行しない)。実行ビットは配布経路(zip・
# アーカイブ展開・一部の同期ツール)で落ちることがあり、そこで「データ源が無い」ではなく
# 「Permission denied」という**別の顔をした失敗**になるのを避ける。verify.sh も同じ流儀。
ND_RC=0
bash "$NDTASKS" --format json ${EXPLICIT[@]+"${EXPLICIT[@]}"} > "$tmp/tasks.json" 2> "$tmp/nd.err" || ND_RC=$?
[ ! -s "$tmp/nd.err" ] || cat "$tmp/nd.err" >&2
if [ "$ND_RC" -ge 2 ]; then
  echo "✗ nd-tasks.sh が rc=$ND_RC で失敗した — ボードは書かない。" >&2
  exit "$ND_RC"
fi
[ "$ND_RC" -eq 0 ] || echo "⚠ nd-tasks.sh が書式違反を報告している(rc=$ND_RC)。ボードは描くが、上の指摘を先に直すこと。" >&2

# --- 所在バッジ(--branches のときだけ。git が失敗しても本体は殺さない) ----------
# 何を集めるか: **基準ブランチ(main 相当)にまだ載っていないコミット**のメッセージ。
#   ⚠️ ボツ案1: `git log --all --grep <ID> --format='%D'`。**実測で両方向に壊れていた** ——
#      %D は「そのコミットを**指している ref**」なので、(a) 起票コミットが main の先端に
#      あるだけで、そこに乗っているだけの無関係なブランチ名が全 ID に付く(このリポジトリで
#      H-2/H-29/H-30/H-31 に feat/harness-pre-commit が誤って付いた)。(b) 逆に、
#      ブランチの2つ手前のコミットで言及していると ref が付いていないので**何も出ない**
#      (H-15/H-27 が実際にそうだった)。誤検知と見逃しが同時に出る検知器は使えない。
#   ⚠️ ボツ案2: `git branch -a --contains <sha>`。main 上のコミットは**全ブランチが含む**ので、
#      ほぼ全 ID に全ブランチ名が付いた(実測)。「所在」の意味を成さない。
#   採った案: 基準ブランチとの差分(`main..<branch>`)にだけ現れるコミット = **まだマージ
#      されていない作業**。これが「いまどこで触られているか」の実体で、main を除外せよという
#      要求とも整合する(main に載った時点で、それはもう「所在」ではなく履歴)。
#   コストは ID 数に依存しない —— ブランチ本数ぶんの git log を1回ずつ回すだけで、
#   ID との突き合わせは python 側でまとめて行う(ID×git log の掛け算にはしない)。
: > "$tmp/branches"
if [ "$WANT_BRANCHES" -eq 1 ]; then
  BASE="${HARNESS_BOARD_BASE:-}"
  if [ -z "$BASE" ]; then
    ORIGIN_HEAD="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    ORIGIN_HEAD="${ORIGIN_HEAD#origin/}"
    for cand in "$ORIGIN_HEAD" main master; do
      [ -n "$cand" ] || continue
      if git rev-parse --verify --quiet "refs/heads/$cand" >/dev/null 2>&1; then BASE="$cand"; break; fi
    done
  fi
  if [ -z "$BASE" ]; then
    # 強化機能なので本体は続行する。ただし**黙って消えない**(原則4)。
    echo "⚠ 基準ブランチ(origin/HEAD / main / master)が見つからない — 所在バッジは出さない。HARNESS_BOARD_BASE=<branch> で指定できる。" >&2
  elif ! git for-each-ref --format='%(refname:short)' refs/heads refs/remotes > "$tmp/refs" 2>/dev/null; then
    echo "⚠ git for-each-ref が失敗した — 所在バッジは出さない(ボード本体は続行)。" >&2
  else
    # レコード形式: <ブランチ名> US <未マージのコミットメッセージ全部> RS
    # US(0x1f)/ RS(0x1e)を使うのは nd-tasks.sh と同じ理由 —— コミットメッセージに
    # 出てこない制御文字だから(タブや | は普通に出る)。
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      # refs/remotes/origin/HEAD は for-each-ref から "origin" という名前で出てくる。
      # ブランチではなく既定ブランチへの別名なので落とす(残すと main の別名がバッジに出る)。
      case "$ref" in origin|*/HEAD) continue ;; esac
      name="${ref#origin/}"
      [ "$name" != "$BASE" ] || continue
      if ! blob="$(git log "$BASE..$ref" --format='%s%n%b' 2>/dev/null)"; then
        echo "⚠ git log $BASE..$ref が失敗した — このブランチは所在バッジから外す。" >&2
        continue
      fi
      [ -n "$blob" ] || continue
      printf '%s\037%s\036' "$name" "$blob"
    done < "$tmp/refs" >> "$tmp/branches"
  fi
fi

# --- 描画(python3。テンプレートはこの中に埋め込んである) -----------------------
# ⚠️ プログラムは一時ファイルへ書いて `python3 <file>` で渡す。`PY=$(cat <<'PY' …)` の形に
#    してはいけない —— **bash 3.2(macOS 標準)は $( ) の中では引用符付きヒアドキュメントの
#    中身まで走査し、本文のバッククォートをコマンド置換の開始と誤認して構文エラーになる**
#    (nd-tasks.sh が awk プログラムで同じ罠を踏んで直した経緯がそのまま当てはまる。
#     この python にはマークダウンのコードスパン処理があるのでバッククォートが必ず出る)。
# 引数ではなく環境変数で渡すのは、値に空文字が入りうる(BRANCHES / BASE)ため —— 位置引数だと
# 空を渡したときに数がズレる。
cat > "$tmp/render.py" <<'PY'
# -*- coding: utf-8 -*-
"""着手順ボードの描画。入力は nd-tasks.sh の JSON、出力は自己完結の HTML 1枚。

**ここに推論は無い。**同じ入力からは必ず同じ HTML が出る(唯一の非決定は生成時刻)。
テンプレート(CSS / レイアウト / JS)はこのファイルの下部に文字列として置いてある。
"""
import html
import json
import os
import re
import sys
import datetime

JSON_PATH   = os.environ["BOARD_JSON"]
OUT_PATH    = os.environ["BOARD_OUT"]
BRANCH_PATH = os.environ.get("BOARD_BRANCHES", "")
VERSION     = os.environ.get("BOARD_VERSION", "?")
WARN_CHARS  = int(os.environ.get("BOARD_WARN_CHARS", "8000"))
WARN_TOKENS = int(os.environ.get("BOARD_WARN_TOKENS", "3000"))
# 切り詰めの壁(#70460)。バーの「ここを越えると無言で切られる」マーカーに使う。
# ⚠️ 既定値を書いてはいるが、これは budgets.sh が読めない環境用の保険ではない ——
#    シェル側が `[ -r "$BUDGETS" ]` で先に落としているので、実運用でこの既定は使われない。
HARD_CHARS  = int(os.environ.get("BOARD_HARD_CHARS", "10000"))
BASE_BRANCH = os.environ.get("BOARD_BASE", "")

def warn(msg):
    """診断は必ず stderr へ。stdout はパス1行だけという契約を壊さない。"""
    sys.stderr.write("⚠ %s\n" % msg)

with open(JSON_PATH, encoding="utf-8") as fp:
    data = json.load(fp)
items = data.get("items", [])
files = data.get("files", [])

# =============================================================================
# ND 全文の読み込み(ファイルにつき1回だけ)
# =============================================================================
# **抽出できなかったときに空を出さない**のが唯一の要件(原則4)。ND の構成は配布先ごとに
# 揺れるので、想定と違う形は必ずあるものとして扱い、「無かった」ではなく
# 「(抽出できず: 理由)」を画面に出す —— 空欄は「現在地が書かれていない」と読まれてしまう。
MISSING = "抽出できず"

_nd_cache = {}

def read_lines(path):
    """ND の全行。**同じファイルは2度読まない**(現在地・目次・完了記録が同じ本文を使う)。

    v0.1.0 では現在地/目次の描画時に1回読んでいた。v0.2.0 で完了記録も要るようになったが、
    読み込みを増やさずキャッシュに寄せてある —— 読む回数が増えると、片方だけ古い行を見て
    「バッジは ✔ なのに目次には出ない」のような**説明のつかない不整合**を作れてしまう。
    失敗(None)もキャッシュする: 読めないファイルを描画のたびに開き直しても結果は同じで、
    警告だけが件数ぶん重複して出る。
    """
    if path in _nd_cache:
        return _nd_cache[path]
    try:
        with open(path, encoding="utf-8", errors="replace") as fp:
            out = fp.read().split("\n")
    except OSError as e:
        warn("ND が読めない: %s (%s)" % (path, e))
        out = None
    _nd_cache[path] = out
    return out

# --- 完了記録(着手順から降ろされた項目)の ID 集合 -------------------------------
# ⚠️ **見出し名(「## 完了記録」)には依存しない。**依存させると、配布先が節名を変えた
#    瞬間に黙って 0 件になる —— それは「アーカイブが無い」と区別がつかない(原則4)。
#    代わりに**行の書式**を読む: `- ~~`H-3` …~~ ✅ 2026-08-08`。取り消し線が付いた
#    箇条書きの先頭 ID、というのはこの正典で「降ろした」を意味する書き方そのもので、
#    意味を運んでいるのは節ではなく行の側。
# ⚠️ 走査範囲は session-head-end マーカーより下だけ(マーカーが無ければ全体)。
#    上には**着手順**があり、そこの `[x]` 項目は JSON に done として出てくる ——
#    アーカイブ表は「着手順に**居ない** ID」を引くためだけに使うので、仮に混ざっても
#    by_id が先に当たって害は無いが、走査範囲を絞れる場所で絞らない理由も無い。
ARCHIVED_RE = re.compile(r"^\s*[-*]\s+~~\s*`?([A-Za-z]+-\d+)`?")
# ✅ / ✔ の後ろの日付。無くても構わない(その場合は日付なしで「完了記録にあり」とだけ出す)。
ARCH_DATE_RE = re.compile(r"[✅✔][^\d\n]{0,4}(\d{4}-\d{2}-\d{2})")
# 検知器の自己検査用: 「取り消し線付きの箇条書き」らしき行(ID が取れたかどうかに関係なく)。
STRUCK_RE = re.compile(r"^\s*[-*]\s+~~")

def extract_archived(lines, label):
    """{id: 完了日 or ""} を返す。取れなかった理由が言えるように、鳴らすべき時は鳴らす。"""
    if lines is None:
        return {}
    start = 0
    for i, l in enumerate(lines):
        if l.startswith("<!-- session-head-end"):
            start = i + 1
            break
    out, struck = {}, 0
    for l in lines[start:]:
        if STRUCK_RE.match(l):
            struck += 1
        m = ARCHIVED_RE.match(l)
        if not m:
            continue
        d = ARCH_DATE_RE.search(l)
        # 同じ ID が2回出てきたら**先勝ち**。ID の再利用は正典が禁じているので、
        # 2回出るのは書き間違い —— 黙って上書きするより最初の記述を残す方が読みが安定する。
        out.setdefault(m.group(1), d.group(1) if d else "")
    if struck and not out:
        # 「取り消し線の行はあるのに ID が1つも取れない」= 書式が変わったかパーサが死んだ。
        # **0件を静かに通さない**(原則4)。逆に struck==0 なら本当に完了記録が空なだけ。
        warn("%s: 取り消し線付きの項目が %d 行あるのに完了記録の ID を1つも抽出できなかった "
             "—— 書式が変わった可能性がある(期待する形: `- ~~`H-3` …~~ ✅ 2026-08-08`)。" % (label, struck))
    return out

# 全 ND を先に読んでおく。**依存辺の分類より前**に居る必要がある —— 「着手順に無い ID」を
# 参照先なしと呼んでよいかは、完了記録を見るまで決められないため。
# ⚠️ 表は**全 ND を混ぜた1本**にしてある(どの ND の完了記録から来たかは持たない)。
#    ID は接頭辞でコンポーネントが分かれている(H- / IOS-)ので衝突しないし、「どちらの
#    ファイルで完了したか」を持っても**今この画面で使う場所が無い**。使わない情報を
#    持ち回ると、次に触る人がそれを維持する義務だけを負う(原則1・原則2)。
archived = {}       # id -> 完了日("" もありうる)
for f in files:
    p = f.get("file", "")
    if not p:
        continue
    label = f.get("component") or f.get("repo") or os.path.basename(os.path.dirname(p))
    for k, v in extract_archived(read_lines(p), label).items():
        archived.setdefault(k, v)

# =============================================================================
# 依存辺の抽出 —— **H-15 が入ったら差し替えるのはこの関数だけ**
# =============================================================================
# 正典は依存を機械可読に持っていない。あるのは項目本文の `依存: H-7` という散文だけなので、
# そこを正規表現で拾う。ID の形は nd-tasks.sh の ID 正規表現と**同じ**にしてある
# (`[A-Za-z]+-\d+`)—— H-/IOS- に決め打ちすると、配布先の別接頭辞(P- 等)で黙って
# 0件になる。0件は「依存が無い」ではなく「パーサが死んだ」に見えなければならない(原則4)。
DEP_RE = re.compile(r"依存:\s*([A-Za-z]+-\d+)")

def extract_edges(items):
    """[(from, to), ...] を返す。from が to に依存している(to が終わらないと from は動けない)。

    H-15 後の差し替え方:
      正典に `→ 依存: H-7` を書式として持たせ、nd-tasks.sh が JSON へ `deps: [...]` を
      吐くようになったら、この関数の中身を `[(it["id"], d) for it in items for d in it.get("deps", [])]`
      に置き換えるだけでよい。**呼び出し側(blocked 判定・focus・タイル)は 1 行も変わらない。**
    """
    edges, seen = [], set()
    for it in items:
        text = (it.get("summary") or "") + "\n" + (it.get("detail") or "")
        for m in DEP_RE.finditer(text):
            tgt = m.group(1)
            if tgt == it["id"]:
                continue  # 自己参照(書き間違い)は辺にしない。循環の入口を1つ潰しておく
            key = (it["id"], tgt)
            if key in seen:
                continue  # summary と detail の両方に書かれていても1本
            seen.add(key)
            edges.append(key)
    return edges

by_id = {it["id"]: it for it in items}
edges_all = extract_edges(items)

# 辺の4分類。**捨てずに分ける**のが要点:
#   blocking … 相手が着手順にいて未完了 → これだけが blocked を作る
#   settled  … 相手が着手順にいて完了済み(`[x]`)→ 情報としては出すが blocked にしない
#   archived … 相手は着手順に居ないが**完了記録にある** → 済んでいる。v0.2.0 で新設。
#              v0.1.0 はこれを下の missing と混ぜて「参照先なし」と表示していた ——
#              終わっている H-3 / H-28 が「行方不明」に見えるのは**事実として誤り**で、
#              しかも「棚卸しで降ろすほど誤検知が増える」という**運用に逆行する壊れ方**だった。
#   missing  … ファイル全体のどこにも無い = 書き間違いか、存在しない ID を挙げた散文。
#              ここで初めて「参照先なし」を名乗ってよい。blocked にはしないが、
#              **黙って捨てもしない** —— 捨てると「辺が2本のはずが1本しか出ない」ときに
#              気づけなくなる。
#              ⚠️ **この分類器は「散文中の例」と「実在の依存」を区別できない。**判定材料は
#                 「相手の ID が実在するか」だけだから。実例: H-15 の本文にある
#                 `→ 依存: H-3` は**書式の説明**であって実在の依存ではないが、H-3 が完了記録に
#                 実在するので archived と判定される(= ⇐ H-3 ✔ と出る)。誤りではあるが
#                 **害の無い側の誤り** —— blocked を作らず、行も塞がない。区別できるように
#                 するには正典側に「依存」の書式が要る(それが H-15 そのもの)。
blocking, settled, archived_e, missing = [], [], [], []
for f, t in edges_all:
    tgt = by_id.get(t)
    if tgt is None:
        (archived_e if t in archived else missing).append((f, t))
    elif tgt.get("status") == "open":
        blocking.append((f, t))
    else:
        settled.append((f, t))

blocked_by = {}
for f, t in blocking:
    blocked_by.setdefault(f, []).append(t)
# blocked ではない辺は、種類を持ったまま1本の列にする(バッジの見た目が種類で変わるため)。
# 順序は settled → archived → missing の固定。**辺の出現順に並べない**のは、
# 同じ ND から毎回同じ HTML が出るという契約(決定論)を、分類の都合で崩さないため。
other_deps = {}
for kind, lst in (("settled", settled), ("archived", archived_e), ("missing", missing)):
    for f, t in lst:
        other_deps.setdefault(f, []).append((t, kind))

# =============================================================================
# 所在バッジ(--branches)
# =============================================================================
def load_branches(path, ids):
    """{id: [branch, ...]} を返す。ファイルが無い / 空なら空の辞書(= バッジ無し)。"""
    out = {}
    if not path or not os.path.exists(path) or os.path.getsize(path) == 0:
        return out
    with open(path, encoding="utf-8", errors="replace") as fp:
        raw = fp.read()
    # ID の前後を縛らないと `H-2` が `H-28` に誤爆する(実際に H-2 と H-28 が同居している)。
    pats = [(i, re.compile(r"(?<![A-Za-z0-9-])" + re.escape(i) + r"(?![0-9])")) for i in ids]
    for rec in raw.split("\x1e"):
        if "\x1f" not in rec:
            continue
        name, blob = rec.split("\x1f", 1)
        name = name.strip()
        if not name:
            continue
        for i, pat in pats:
            if pat.search(blob):
                lst = out.setdefault(i, [])
                if name not in lst:  # ローカルと origin/ で同じ名前が2回来るので重複除去
                    lst.append(name)
    return out

open_ids = [it["id"] for it in items if it.get("status") == "open"]
branches = load_branches(BRANCH_PATH, open_ids)

# =============================================================================
# 最小のマークダウン変換
# =============================================================================
# **凝った変換器は書かない。**必要なのは「読めること」であって忠実な再現ではない。
# 対応するのは **強調** / `コード` / 行頭 `- ` のリストだけ。それ以外は段落として出す。
# ⚠️ 順序が命 —— **先に HTML エスケープしてから**記号を置換する。逆にすると、生成した
#    <strong> ごとエスケープされて画面に <strong> という文字列が出る。
def inline(s):
    s = html.escape(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    return s

def mini_md(lines):
    """現在地の本文を最小限だけ HTML にする。入力は生の行(改行なし)。

    **2段構えにしてある(1回で書けそうに見えるが、書くと壊れる)。**
      (1) 物理行を論理ブロックへ畳む —— 正典は 90 桁前後で**折り返して**書かれており、
          `**強調**` が行をまたぐことが普通にある(実測: 「**どの配布先が\\n複合コマンドで
          入れたかは未調査。**」)。行ごとに inline() を掛けると開きと閉じが別の行に落ちて
          **`**` がそのまま画面に出る。**畳んでから変換すれば起きない。
      (2) 畳んだ結果を HTML にする。
    空行はブロックの区切りにするだけで <ul> は閉じない —— 箇条書きの項目の間に空行を挟む
    書き方(この正典が実際にそう)で、リストが項目ごとの <ul> に分裂するのを防ぐ。
    """
    # --- (1) 畳む。None は空行(= 折り返しの連結を打ち切る印) ---
    blocks = []
    for raw in lines:
        s = raw.rstrip()
        if not s.strip():
            blocks.append(None)
            continue
        m = re.match(r"^\s*[-*]\s+(.*)$", s)
        if m:
            blocks.append(["li", m.group(1)])
            continue
        if (s.startswith(" ") or s.startswith("\t")) and blocks and blocks[-1]:
            blocks[-1][1] += " " + s.strip()   # 字下げされた折り返し
            continue
        kind, text = ("q", s.lstrip("> ")) if s.startswith(">") else \
                     ("sub", s.lstrip("# ")) if s.startswith("#") else ("p", s)
        # 同じ種類のブロックが空行を挟まずに続くなら、それは段落の折り返し(字下げ無しの続き)。
        # li だけは畳まない —— `- ` は常に新しい項目の開始だから。
        if blocks and blocks[-1] and blocks[-1][0] == kind and kind != "li":
            blocks[-1][1] += " " + text
        else:
            blocks.append([kind, text])
    # --- (2) HTML にする ---
    out, in_ul = [], False
    for b in blocks:
        if b is None:
            continue
        kind, text = b
        if kind == "li":
            if not in_ul:
                out.append("<ul>")
                in_ul = True
            out.append("<li>" + inline(text) + "</li>")
            continue
        if in_ul:
            out.append("</ul>")
            in_ul = False
        cls = {"p": "", "q": ' class="q"', "sub": ' class="sub"'}[kind]
        out.append("<p%s>%s</p>" % (cls, inline(text)))
    if in_ul:
        out.append("</ul>")
    return "\n".join(out)

def plain(md):
    """行に出す用のプレーンテキスト化。強調・コード・打ち消しの**記号だけ**を落とす。"""
    s = (md or "").replace("\n", " ")
    s = re.sub(r"\*\*(.+?)\*\*", r"\1", s)
    s = re.sub(r"~~(.+?)~~", r"\1", s)
    s = s.replace("`", "")
    return re.sub(r"\s+", " ", s).strip()

# =============================================================================
# ND から「現在地」とカタログ目次を切り出す(本文は上の read_lines が既に読んである)
# =============================================================================
def section_now(lines):
    """「## 現在地」〜次の「## 」(本来は「## 着手順」)の間を返す。(html, note)。"""
    if lines is None:
        return ('<p class="missing">(%s: ファイルが読めない)</p>' % MISSING, None)
    start = None
    for i, l in enumerate(lines):
        if re.match(r"^##\s*現在地", l):
            start = i
            break
    if start is None:
        return ('<p class="missing">(%s: 「## 現在地」の見出しが無い)</p>' % MISSING, None)
    end, end_line = len(lines), ""
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("## "):
            end, end_line = j, lines[j]
            break
    body = mini_md(lines[start + 1:end])
    note = None
    if not re.match(r"^##\s*着手順", end_line):
        # 切り出せてはいるが、想定した並び(現在地 → 着手順)ではない。黙って通さず但し書きを出す。
        note = "現在地の次の見出しが「## 着手順」ではない(%s)" % (end_line.strip() or "見出しが無いまま EOF")
    if not body.strip():
        body = '<p class="missing">(%s: 「## 現在地」節が空)</p>' % MISSING
    return (body, note)

def section_toc(lines):
    """session-head-end マーカー以降の ## / ### をカタログ目次として返す。

    リンクは張らない —— 目次が指すのは**同じ ND ファイルの節**であって、この HTML の中には
    その本文が無い(頭だけが予算制で、カタログは on-demand に Read / grep するもの)。
    「押せそうで押せないリンク」を作るより、テキストのまま置く方が誤解が無い。
    """
    if lines is None:
        return '<p class="missing">(%s: ファイルが読めない)</p>' % MISSING
    mark = None
    for i, l in enumerate(lines):
        if l.startswith("<!-- session-head-end"):
            mark = i
            break
    if mark is None:
        return '<p class="missing">(%s: session-head-end マーカーが無い)</p>' % MISSING
    out = []
    for l in lines[mark + 1:]:
        m = re.match(r"^(#{2,3})\s+(.*)$", l)
        if m:
            out.append('<li class="h%d">%s</li>' % (len(m.group(1)), inline(m.group(2).strip())))
    if not out:
        return '<p class="missing">(%s: マーカー以降に ## / ### 見出しが無い)</p>' % MISSING
    return '<ul class="toc">' + "".join(out) + "</ul>"

# =============================================================================
# 板(コンポーネント)ごとの組み立て
# =============================================================================
# 板の単位は **ND ファイル1本**。component 名で束ねないのは、単一プロダクト型
# (docs/next-directions.md)では component が空になりうるため。ファイルは必ず1本に定まる。
boards = []
for f in files:
    path = f.get("file", "")
    mine = [it for it in items if it.get("file") == path]
    name = f.get("component") or f.get("repo") or os.path.basename(os.path.dirname(path))
    boards.append({"file": path, "name": name, "items": mine, "meta": f})
# files[] に出てこないファイルの項目(通常は起きない)を落とさない。落とすと件数が合わなくなる。
known = set(f.get("file", "") for f in files)
orphan = [it for it in items if it.get("file") not in known]
if orphan:
    warn("files[] に無いファイルの項目が %d 件ある — 「(所属不明)」として出す。" % len(orphan))
    boards.append({"file": "", "name": "(所属不明)", "items": orphan, "meta": {}})

def first_actionable(board):
    """そのボードの「次」= blocked でない最初の未完了。全部 blocked なら None。"""
    for it in board["items"]:
        if it.get("status") == "open" and it["id"] not in blocked_by:
            return it["id"]
    return None

for b in boards:
    b["next"] = first_actionable(b)
    if b["next"] is None and any(it.get("status") == "open" for it in b["items"]):
        # 「次が無い」は正常ではないので画面にもタイルにも出す(空欄にしない)。
        warn("%s: 未完了はあるが全て blocked —— 先に依存側を進める必要がある。" % b["name"])

# =============================================================================
# 依存辺のレール(`git log --oneline --graph` 方式・**文字で**描く)
# =============================================================================
# バッジ(⇐ / ⇠)は「誰に依存しているか」を名指しするが、**どこからどこへ跨いでいるか**は
# 読めない。ここでは各行の右端に罫線の列を足し、上流の行から下流の行へ線を1本引く。
#
# 【なぜ文字か(SVG のピクセル計算を採らなかった理由)】
#   線の座標を px で計算するには「行の高さ」が要る。行の高さはフォント・ズーム倍率・
#   日本語の行送り・テーマ(太字の有無)で変わるので、**生成時に確定できない値**を
#   生成時に固定することになる。ズレたときに直す手段も無い(HTML を作り直すしかない)。
#   文字なら、行揃えはブラウザの行組みがやるので**定義上ズレない**し、色は currentColor で
#   テーマに自動追随し、Ctrl-F の対象にもならない。ライブラリも 0 本。
#
# 【描き方 —— 方向ビットの合成】
#   セルごとに N/S/E/W の4ビットを立て、最後に1文字へ写像する。分岐を場合分けで書くと
#   「縦線の上を横線が横切る」「同じ行で1本が終わり別の1本が始まる」の組み合わせを
#   数え落とすが、ビットなら**合流が OR 1つで閉じる**(実際 ┼ ┬ ┴ ┤ ├ は全部この OR の結果)。
N, S, E, W = 1, 2, 4, 8
GLYPH = {
    0: " ",
    N | S: "│", E | W: "─",
    S | W: "╮", N | W: "╯", S | E: "╭", N | E: "╰",
    N | S | W: "┤", N | S | E: "├", E | W | S: "┬", E | W | N: "┴",
    N | S | E | W: "┼",
    # 片方向だけ立っている状態は本来出ないが、出たときに KeyError で落とすより線として出す
    # (描画の欠けは画面を見れば分かる。例外は post-commit hook から呼ばれると誰も見ない)。
    N: "│", S: "│", E: "─", W: "─",
}

def assign_lanes(spans):
    """[(top, bot, ...)] にレーン番号を振る。区間の**貪欲詰め**(first-fit)。

    レーン0が本文に最も近い。「last < top」で厳密に判定するので、**端点を共有する2本は
    別レーンへ行く**(A→B と A→C は同じ行に角が2つ必要なので、同じレーンには置けない)。
    ⚠️ ボツ案: 交差数の最小化(レーン割り当ての最適化)。現実の辺は2〜4本で、貪欲と最適の
       差が出るほど混まない。**混んだときに困るのは辺の本数ではなく画面の幅**なので、
       最適化を足しても解ける問題が増えない。
    """
    spans = sorted(spans, key=lambda s: (s[0], s[1]))
    tails, out = [], []           # tails[L] = そのレーンで最後に使った下端の行番号
    for sp in spans:
        top, bot = sp[0], sp[1]
        lane = None
        for L, last in enumerate(tails):
            if last < top:
                tails[L] = bot
                lane = L
                break
        if lane is None:
            tails.append(bot)
            lane = len(tails) - 1
        out.append((lane,) + tuple(sp))
    return out, len(tails)

def build_rails(board):
    """board["rails"] に**行と同じ長さ**のリスト(各行のレール HTML)を入れる。辺が無ければ空。

    描くのは**両端がこのボードの行にある辺**だけ。アーカイブ済み(H-3 等)への辺は
    終点の行が存在しないので描かない —— そこはバッジの担当(役割分担であって手抜きではない)。
    """
    pos = {it["id"]: i for i, it in enumerate(board["items"])}
    block_set = set(blocking)
    spans = []
    for f, t in edges_all:
        if f in pos and t in pos and f != t:
            a, b2 = pos[t], pos[f]        # t = 上流(依存先)、f = 下流(依存元)
            if a > b2:
                # 上流が下流より**下**にある = 着手順の位置と依存が矛盾している。
                # レールは向きを持たない絵(端点はどちらも ●)なので、ここだけは画面で
                # 区別できない —— **黙って普通の線として描かず** stderr で名指しする。
                # ⚠️ これは「blocked」とは別の指摘。blocked は位置に関係なく起きるが、
                #    こちらは「上から順にやると必ず詰まる並びになっている」という順序の欠陥。
                warn("%s: 着手順の並びが依存と逆 —— %s は %s に依存しているのに、%s の方が"
                     "下にある(上から着手すると必ず詰まる)。" % (board["name"], f, t, t))
            spans.append((min(a, b2), max(a, b2), (f, t) in block_set))
    board["rails"] = []
    if not spans:
        return
    laned, nlanes = assign_lanes(spans)
    nrows, ncols = len(board["items"]), nlanes + 1   # col 0 は ● を置く列
    grid = [[0] * ncols for _ in range(nrows)]
    hot = [[False] * ncols for _ in range(nrows)]    # 未完了の依存(= 生きた関門)を通る辺
    dot = [False] * nrows
    for lane, top, bot, is_block in laned:
        col = lane + 1
        dot[top] = dot[bot] = True
        for r in (top, bot):
            for c in range(1, col):      # ● から角までの横棒(途中の縦線とは OR で合流する)
                grid[r][c] |= E | W
                hot[r][c] = hot[r][c] or is_block
            hot[r][col] = hot[r][col] or is_block
            hot[r][0] = hot[r][0] or is_block
        grid[top][col] |= W | S          # 上端: 西から来て下へ折れる
        grid[bot][col] |= W | N          # 下端: 下から来て西へ折れる
        for r in range(top + 1, bot):
            grid[r][col] |= N | S
            hot[r][col] = hot[r][col] or is_block
    for r in range(nrows):
        cells = []
        for c in range(ncols):
            ch = "●" if (c == 0 and dot[r]) else (" " if c == 0 else GLYPH[grid[r][c]])
            # 色分けは「その線が**まだ生きている関門**か」だけ。2本が同じセルで交差したら
            # 生きている方を優先する(hot が or で立っているのはそのため)。
            cells.append('<i class="hot">%s</i>' % ch if hot[r][c] and ch != " " else ch)
        board["rails"].append("".join(cells))

for b in boards:
    build_rails(b)

# --- 行 -----------------------------------------------------------------------
def badge(cls, text, tip):
    return '<span class="%s" title="%s">%s</span>' % (cls, html.escape(tip), html.escape(text))

def render_row(it, is_next, rail):
    done = it.get("status") == "done"
    full = plain(it.get("summary"))
    cls = []
    if done:
        cls.append("done")
    elif is_next:
        cls.append("next")
    if it["id"] in blocked_by:
        cls.append("blocked")
    glyph = "✔" if done else ("■" if is_next else "☐")
    # タイトルは切り詰めない。CSS(.t の overflow:hidden + text-overflow:ellipsis)で畳む。
    # ⚠️ ボツ案: 生成時に N 文字で切って「…」を付ける(最初の版はそうしていた)。やめた理由は
    #    (1) ブラウザの Ctrl-F で探せなくなる、(2) 幅が変わっても切る位置が固定で、広い画面で
    #    無駄に切れる、(3) バッジ(⇠ / ⎇)は flex:none なので、CSS で畳めば本文だけが縮んで
    #    バッジは必ず見える —— 生成時に切ると「切ったのに、まだ溢れる」が起こりうる。
    body = html.escape(full)
    if done:
        body = "<s>%s</s>" % body
    elif is_next:
        body = "<b>%s</b>" % body
    parts = [
        '<span class="g">%s</span>' % glyph,
        '<span class="id">%s</span>' % html.escape(it["id"]),
        '<span class="t">%s</span>' % body,
    ]
    for t in blocked_by.get(it["id"], []):
        parts.append(badge("dep wait", "⇠ %s 待ち" % t, "%s(未完了)に依存していて着手できない" % t))
    for t, kind in other_deps.get(it["id"], []):
        if kind == "settled":
            parts.append(badge("dep past", "⇐ %s ✔" % t,
                               "%s に依存。%s は着手順で完了済みなので blocked ではない" % (t, t)))
        elif kind == "archived":
            # v0.2.0 の主眼。**「着手順に無い」と「どこにも無い」を同じ顔で出さない。**
            when = archived.get(t) or ""
            parts.append(badge("dep past", "⇐ %s ✔" % t,
                               "%s に依存。%s は完了記録にあり%s。blocked ではない"
                               % (t, t, "(%s)" % when if when else "(完了日は記録から拾えなかった)")))
        else:
            parts.append(badge("dep gone", "⇐ %s" % t,
                               "%s に依存と書かれているが、%s は着手順にも完了記録にも無い"
                               "(散文中の例、または書き間違い)。blocked には数えない" % (t, t)))
    for br in branches.get(it["id"], []):
        parts.append(badge("br", "⎇ %s" % br, "%s に言及する未マージのコミットが %s にある" % (it["id"], br)))
    # レールは**必ず最後**(= 行の右端)。バッジの手前に置くと、バッジの幅が行ごとに違うぶん
    # レール列の x 位置がズレて縦線が繋がらない。辺の無いボードでは rail=None で列ごと出さない
    # (空の列を全ボードに出すと、何も無いのに「何かがある」ように見える幅を毎行占める)。
    if rail is not None:
        parts.append('<span class="rail">%s</span>' % rail)
    return '<li%s data-id="%s" title="%s">%s</li>' % (
        (' class="%s"' % " ".join(cls)) if cls else "",
        html.escape(it["id"]),
        html.escape(full),
        "".join(parts),
    )

# --- 頭サイズのミニ棒グラフ -----------------------------------------------------
# 「N件 超過」を捨ててバーにした理由はファイル冒頭 (3)。ここでの設計上の要点は2つ:
#   (a) **目盛りは全ボード共通**(下の SCALE_*)。ボードごとに正規化すると 8,934字 と
#       3,825字 のバーが同じ長さになり、棒グラフである意味が消える。
#   (b) 予算は**マーカー(縦線)**であって上限ではない。バーは予算を超えたら超えた分だけ
#       伸びる —— 「予算で頭打ち」に描くと、2倍超過と 1.01倍超過が同じ絵になる。
def _scale(values, floor):
    """目盛りの上端。予算(floor)と実測の最大値の**大きい方**を基準に少し余白を足す。

    余白 8% は「マーカーが右端に貼り付いて見えなくなる」のを防ぐためだけの値。
    予算内しか無いときは floor が効くので、バーは「予算に対してどれだけ余っているか」を示す。
    """
    return max([floor] + [v for v in values if v]) * 1.08

SCALE_CHARS  = _scale([f.get("head_chars") for f in files], HARD_CHARS)
SCALE_TOKENS = _scale([f.get("head_tokens_est") for f in files], WARN_TOKENS)

def _pct(v, scale):
    return "%.1f%%" % (100.0 * v / scale) if scale else "0%"

def bar(label, cur, budget, scale, unit, marks):
    """1本ぶんの HTML。marks は [(値, class, 説明), ...] の縦線。"""
    over = cur > budget
    ticks = "".join('<i class="mk%s" style="left:%s" title="%s"></i>'
                    % (c and " " + c, _pct(v, scale), html.escape(t)) for v, c, t in marks)
    return ('<div class="bar%s"><span class="bk">%s</span>'
            '<span class="track"><span class="fill" style="width:%s"></span>%s</span>'
            '<span class="bv">%s <small>/ %s%s</small></span></div>'
            % (" over" if over else "", label, _pct(min(cur, scale), scale), ticks,
               "{:,}".format(cur), "{:,}".format(budget), unit))

def size_bars(meta):
    if meta.get("head_chars") is None:
        # 空欄にしない(原則4)。頭が測れていないのは「予算内」ではなく「測れていない」。
        return '<div class="bar-miss">頭サイズ: %s(files[] に head_chars が無い)</div>' % MISSING
    out = bar("文字", meta["head_chars"], WARN_CHARS, SCALE_CHARS, "字",
              [(WARN_CHARS, "", "警告 %s字(予算)" % "{:,}".format(WARN_CHARS)),
               (HARD_CHARS, "hard", "切り詰め %s字 —— SessionStart の stdout はここを超えると"
                                    "無言で切られる(#70460)" % "{:,}".format(HARD_CHARS))])
    tk = meta.get("head_tokens_est")
    if tk is None:
        # **0 として描かない。**「0 tok」は「予算内」に見えるが、実際は測れていない
        # (トークン概算はベンダー固有なので、配布先の JSON に無いことがありうる)。原則4。
        out += '<div class="bar-miss">トークン: %s(files[] に head_tokens_est が無い)</div>' % MISSING
    else:
        out += bar("トークン", tk, WARN_TOKENS, SCALE_TOKENS, " tok",
                   [(WARN_TOKENS, "", "予算 %s tok(毎セッションの実費)" % "{:,}".format(WARN_TOKENS))])
    return out

board_html = []
for b in boards:
    # rails は行と1:1(build_rails が items と同じ長さで作る)。辺が無いボードは空リストなので
    # None を渡してレール列ごと消す。
    rails = b["rails"] or [None] * len(b["items"])
    rows = "\n".join(render_row(it, it["id"] == b["next"], rails[i])
                     for i, it in enumerate(b["items"]))
    lines = read_lines(b["file"]) if b["file"] else None
    now_html, now_note = section_now(lines)
    if now_note:
        warn("%s: %s" % (b["name"], now_note))
        now_html = '<p class="missing">(注意: %s)</p>' % html.escape(now_note) + now_html
    toc_html = section_toc(lines)
    # ⚠️ v0.2.0: ここには <details> を置かない。現在地には「未検証の危険」「裁定待ち」が
    #    書かれている —— **既定で畳んでよい情報ではない**(ダークパターン)。
    #    目次も同様に常時表示で、代わりに mono の小サイズ + 2カラムで面積を詰めている。
    board_html.append(
        '<div class="board"><h2>%s <span>%d件</span></h2>\n<ul>\n%s\n</ul>\n'
        '<div class="extra"><div class="bars">%s</div>'
        '<div class="sec"><div class="lab">現在地</div><div class="body">%s</div></div>'
        '<div class="sec"><div class="lab">カタログ目次 <small>(本文は ND を Read / grep)</small></div>'
        '<div class="body">%s</div></div>'
        "</div></div>"
        % (html.escape(b["name"]), len(b["items"]), rows, size_bars(b["meta"]), now_html, toc_html)
    )

# --- タイル -------------------------------------------------------------------
# ⚠️ v0.2.0 で「次(<コンポーネント>)」と「頭サイズ」のタイルを外した。前者は ■ が各ボードの
#    先頭で同じことを言っており、後者はバーに吸収された。**残したのは、どのボードを見ても
#    分からない全体量(未完了/完了)と、ボードを跨いで数える依存辺の2つだけ。**
n_open = sum(1 for it in items if it.get("status") == "open")
n_done = len(items) - n_open

tiles = []
tiles.append('<div class="tile"><div class="k">未完了</div><div class="v">%d <small>/ 完了 %d</small></div></div>'
             % (n_open, n_done))
dep_small = "blocked %d" % len(blocked_by)
if settled or archived_e:
    dep_small += " / 解決済み %d" % (len(settled) + len(archived_e))
if missing:
    dep_small += " / 参照先なし %d" % len(missing)
tiles.append('<div class="tile%s"><div class="k">依存辺(自由文)</div><div class="v">%d <small>%s</small></div></div>'
             % (" warn" if blocked_by else "", len(edges_all), dep_small))

# --- focus 用のデータ(ページに埋め込む) ---------------------------------------
# CSP で外部読み込みは全部死ぬ(file:// で開くことも多い)ので、データも JS も inline。
# `</script>` で早期終了させられないよう `<` を < へ逃がすのは JSON 埋め込みの定石。
focus_data = {
    "items": [
        {
            "id": it["id"],
            "title": plain(it.get("summary")),
            "criteria": plain(it.get("done_criteria")) or "",
            "status": it.get("status"),
        }
        for it in items
    ],
    "edges": [{"from": f, "to": t} for f, t in edges_all],
    # focus ビューの上流/下流リストも**同じ解決**を使う(バッジだけ ✔ が出て、クリックしたら
    # 「着手順に無い」と言われる、という食い違いを構造的に作らない)。値は完了日(不明なら "")。
    "archived": archived,
}
data_json = json.dumps(focus_data, ensure_ascii=False).replace("<", "\\u003c")

generated = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
srcs = ", ".join(sorted(set(os.path.basename(os.path.dirname(f.get("file", ""))) or "?" for f in files)))

meta_line = (
    '<span>■ = 次(blocked でない最初の未完了)</span>'
    '<span>☐ = 未完了(上から着手順)</span><span>✔ = 完了</span>'
    '<span>⇠ X 待ち = X(未完了)に依存 → 着手できない</span>'
    '<span>⇐ X ✔ = X に依存。X は完了済み(着手順の <code>[x]</code> か完了記録)</span>'
    '<span>⇐ X = X が ND のどこにも無い(散文中の例 / 書き間違い)</span>'
    '<span class="rail-legend">●─╮ │ ●─╯ = 依存辺。上流の行から下流の行へ</span>'
    '<span>バーの縦線 = 予算(文字は警告 %s / 切り詰め %s、トークンは %s)</span>'
    % ("{:,}".format(WARN_CHARS), "{:,}".format(HARD_CHARS), "{:,}".format(WARN_TOKENS))
)
if branches:
    meta_line += '<span>⎇ = %s に未マージのコミットがあるブランチ</span>' % html.escape(BASE_BRANCH or "基準ブランチ")
meta_line += '<span>行をクリック → 上流/下流(Esc で解除)</span>'

note = (
    "構造の実体は「コンポーネント → 順序付きリスト」の2層で、木ではない。順序は位置が運び、"
    "依存は自由文から %d 本だけ抽出できる(機械可読フィールドは 0。<code>H-15</code> が入ったら "
    "<code>render-board.sh</code> の <code>extract_edges()</code> だけを差し替える)。"
    "全域グラフを描かないのは、29項目のノードが画面に収まらず順序が消えるのを実測したため —— "
    "レールが描くのは**同じボードの中で行から行へ跨ぐ辺だけ**で、近傍の全体が要るときは行をクリックする。"
) % len(edges_all)
if archived_e:
    note += (
        " うち %d 本は完了記録にある ID を指している(%s)—— 着手順から降ろされただけで"
        "終わっているので <code>⇐ … ✔</code> で出し、レールには描かない(終点の行が無い)。"
    ) % (len(archived_e), html.escape(", ".join("%s→%s" % (f, t) for f, t in archived_e)))
if missing:
    note += (
        " 参照先が ND のどこにも無い辺が %d 本ある(%s)—— 書式の説明として本文に書かれた例か、"
        "書き間違い。blocked には数えないが、捨てずに <code>⇐</code> で出している。"
    ) % (len(missing), html.escape(", ".join("%s→%s" % (f, t) for f, t in missing)))

# =============================================================================
# テンプレート
# =============================================================================
# ⚠️ str.format / f-string は使わない —— CSS と JS が波括弧まみれで、全部 {{ }} に
#    エスケープする羽目になる(読めなくなるし、1個忘れると実行時に落ちる)。
#    素朴に __TOKEN__ を replace する方が、この規模では圧倒的に安全。
TEMPLATE = """<!DOCTYPE html>
<html lang="ja">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="generator" content="render-board.sh v__VERSION__">
<title>harness 着手順ボード</title>
<style>
:root{
  --paper:#fafaf7; --ink:#22261f; --sub:#8a9083; --line:#dcdfd6;
  --card:#ffffff; --accent:#3e7c4f; --warn:#b0821f;
  --mono:ui-monospace,'SF Mono',Menlo,monospace;
}
@media (prefers-color-scheme: dark){:root{
  --paper:#16181a; --ink:#e8e6e0; --sub:#7d8377; --line:#33372f;
  --card:#1d211c; --accent:#6fae7f; --warn:#d1a044;
}}
:root[data-theme="dark"]{
  --paper:#16181a; --ink:#e8e6e0; --sub:#7d8377; --line:#33372f;
  --card:#1d211c; --accent:#6fae7f; --warn:#d1a044;
}
:root[data-theme="light"]{
  --paper:#fafaf7; --ink:#22261f; --sub:#8a9083; --line:#dcdfd6;
  --card:#ffffff; --accent:#3e7c4f; --warn:#b0821f;
}
body{background:var(--paper);color:var(--ink);font-family:-apple-system,'Hiragino Sans','Noto Sans JP',sans-serif;
  line-height:1.6;margin:0;padding:2rem 1.25rem 3rem;}
main{max-width:1080px;margin:0 auto;display:flex;flex-direction:column;gap:1.5rem;}
header h1{font-size:1.3rem;margin:0 0 .2rem;}
header p{margin:0;color:var(--sub);font-size:.8rem;}
/* タイルは2枚だけになった(v0.2.0)。grid の auto-fit だと2枚が画面幅いっぱいに
   引き伸ばされて「数字2つのために横 1080px」になるので、flex + 上限幅で左に寄せる。 */
.tiles{display:flex;flex-wrap:wrap;gap:.6rem;}
.tile{background:var(--card);border:1px solid var(--line);border-radius:5px;padding:.55rem .85rem;
  overflow:hidden;min-width:150px;}
.tile .k{font-size:.66rem;letter-spacing:.07em;text-transform:uppercase;color:var(--sub);}
.tile .v{font-size:1.05rem;font-variant-numeric:tabular-nums;margin-top:.1rem;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.tile .v small{font-size:.72rem;color:var(--sub);font-weight:400;}
.tile.warn .v{color:var(--warn);}
.boards{display:grid;grid-template-columns:repeat(auto-fit,minmax(460px,1fr));gap:1rem;align-items:start;}
@media (max-width:520px){.boards{grid-template-columns:1fr;}}
.board{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:.65rem .9rem .8rem;}
.board h2{font-size:.78rem;letter-spacing:.06em;color:var(--sub);margin:.1rem 0 .45rem;
  text-transform:uppercase;display:flex;justify-content:space-between;}
.board h2 span{font-variant-numeric:tabular-nums;}
ul{list-style:none;margin:0;padding:0;font-size:.86rem;}
li{display:flex;align-items:baseline;gap:.55em;padding:.13rem 0;white-space:nowrap;}
/* 行送りをレールに合わせて確定させる(下の .rail のコメント参照)。ここを数値で固定して
   おかないと、レールの字形の高さだけが決め打ちで行間が変わり、縦線が鎖に見える。 */
.board > ul > li{cursor:pointer;border-radius:3px;line-height:1.5;padding:.08rem 0;}
li .g{width:1em;flex:none;color:var(--sub);}
li .id{font-family:var(--mono);font-size:.78em;color:var(--sub);flex:none;width:3.6em;}
/* 本文だけが縮んで畳まれるようにする。バッジは flex:none なので必ず右端に残る。 */
li .t{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;}
li.done, li.done .id{color:var(--sub);}
li.done s{text-decoration-thickness:1px;}
li.next .g{color:var(--accent);}
li.next .id{color:var(--accent);}
li.next b{font-weight:600;}
li.blocked{opacity:.5;}
.dep{font-family:var(--mono);font-size:.72em;border:1px solid var(--line);
  border-radius:3px;padding:0 .35em;margin-left:.3em;flex:none;}
.dep.wait{color:var(--warn);}
.dep.past{color:var(--sub);}
/* 「参照先が ND のどこにも無い」だけを破線にする。完了記録で解決できた ⇐ ✔(.past)と
   同じ見た目にしていたのが v0.1.0 の誤りだった —— 済んでいるものと行方不明を混ぜない。 */
.dep.gone{color:var(--sub);border-style:dashed;}
/* --- 依存辺のレール ---------------------------------------------------------
   縦線が行をまたいで**繋がって見える**ためだけの数値なので、根拠を残す:
     行の高さ = .86rem × 1.5(line-height)+ .08rem×2(padding)≒ 23.2px
     box-drawing 字形の縦の伸び ≒ font-size × 1.19(端末で隙間なくタイルするための設計)
     → レールの font-size を 1.4em(≒19.3px)にすると ink ≒ 23.0px で行の高さとほぼ同じ。
   ⚠️ **大きすぎて重なるのは無害**(縦線が濃くなるだけ)。**小さくて隙間が空くのは有害**
      (鎖に見えて「別の線」と読まれる)。迷ったら大きい側へ倒すこと。
   ⚠️ line-height:1 を必ず付ける —— これが無いと 1.4em の行ボックスが行の高さを押し上げ、
      「フォントを大きくする → 行が高くなる → また隙間が空く」の追いかけっこになる。
   ⚠️ letter-spacing:0 は継承対策。文字幅がズレると縦線が斜めに割れる。
   → **実測(2026-08-10)**: headless Chrome の3倍スクショを画素走査し、レーン0の縦線
     740px 中に背景色の隙間 0(4レーンの合成 ND でも 800px 中 0)。上の算術が机上のまま
     終わらないよう、目視ではなく画素で数えてある(原則4: それらしい数字は 0件より危険)。 */
.rail{font-family:var(--mono);font-size:1.4em;line-height:1;white-space:pre;letter-spacing:0;
  flex:none;color:var(--sub);margin-left:.5em;opacity:.85;}
.rail i{font-style:normal;}                 /* <i> は入れ物として使っているだけ。斜体は要らない */
/* まだ生きている関門(未完了への依存)だけ色を変える。
   ⚠️ ここに opacity:1 を書いても効かない —— 親の opacity は合成グループを作るので、
      子で 1 に戻すことはできない(書くと「効いているつもり」の死んだ宣言が残る)。
      強調は**色だけ**で行う。 */
.rail i.hot{color:var(--warn);}
.rail-legend{font-family:var(--mono);}
.br{font-family:var(--mono);font-size:.72em;color:var(--sub);border:1px dashed var(--line);
  border-radius:3px;padding:0 .35em;margin-left:.3em;flex:none;}
/* focus 中の強調。色は既存トークンの上に薄い面を敷くだけで、両テーマで破綻しない値にした。 */
li.sel{outline:1px solid var(--accent);}
li.hl-up{background:rgba(176,130,31,.14);}
li.hl-down{background:rgba(62,124,79,.14);}
.extra{margin-top:.6rem;border-top:1px solid var(--line);padding-top:.5rem;}
/* --- 頭サイズのミニ棒グラフ ---------------------------------------------------
   単色の div とマーカー線だけ。ライブラリも SVG も使わない —— 必要なのは「予算に対して
   どこにいるか」の一目で、目盛り・凡例・ツールチップの効いたグラフではない。 */
.bars{margin-bottom:.5rem;}
.bar{display:flex;align-items:center;gap:.5em;font-size:.7rem;color:var(--sub);
  font-variant-numeric:tabular-nums;margin:.15rem 0;}
.bar .bk{flex:none;width:4.2em;}                       /* 「文字」「トークン」の見出し */
.bar .track{position:relative;flex:1 1 auto;height:.62rem;background:var(--paper);
  border:1px solid var(--line);border-radius:2px;overflow:hidden;}
.bar .fill{position:absolute;left:0;top:0;bottom:0;background:var(--sub);opacity:.55;}
.bar.over .fill{background:var(--warn);opacity:.75;}
/* 予算のマーカー。実線 = 警告、破線 = 切り詰め(越えたら無言で切られる壁)。 */
.bar .mk{position:absolute;top:-1px;bottom:-1px;width:0;border-left:1px solid var(--ink);opacity:.55;}
.bar .mk.hard{border-left:1px dashed var(--warn);opacity:1;}
.bar .bv{flex:none;min-width:7.5em;text-align:right;}
.bar.over .bv{color:var(--warn);}
.bar .bv small{opacity:.7;}
.bar-miss{font-size:.7rem;color:var(--warn);margin-bottom:.4rem;}
/* --- 現在地 / カタログ目次(v0.2.0: 折りたたみ要素を廃して常時表示)--------------
   ⚠️ **テンプレートの中では、廃した HTML 要素の名前を綴らない**(コメントでも)。
      「出力に折りたたみが1つも無い」は grep で検証する項目なので、コメントが
      偽陽性を出すと検証そのものが役に立たなくなる。要素名は python 側のコメントにある。 */
.sec{font-size:.8rem;margin-top:.45rem;}
.sec .lab{color:var(--sub);font-size:.7rem;letter-spacing:.05em;text-transform:uppercase;}
.sec .lab small{text-transform:none;letter-spacing:0;opacity:.8;}
.sec .body{margin-top:.25rem;}
.sec .body p{margin:.3rem 0;}
.sec .body p.q{color:var(--sub);border-left:2px solid var(--line);padding-left:.5em;}
.sec .body p.sub{font-weight:600;}
.sec .body ul{list-style:disc;padding-left:1.15em;}
.sec .body li{display:list-item;white-space:normal;cursor:default;padding:.08rem 0;}
/* 目次は畳まないぶん面積を詰める: mono の小サイズ + 2カラム。列送りは CSS 任せで、
   JS も列数の計算も要らない(狭い画面では下の 1 カラムへ落ちる)。 */
.sec .body ul.toc{padding-left:0;column-count:2;column-gap:1.1rem;}
.sec .body ul.toc li{list-style:none;font-family:var(--mono);font-size:.75em;color:var(--sub);
  break-inside:avoid;-webkit-column-break-inside:avoid;white-space:normal;}
.sec .body ul.toc li.h3{padding-left:1.1em;}
@media (max-width:640px){.sec .body ul.toc{column-count:1;}}
.missing{color:var(--warn);}
.focus{background:var(--card);border:1px solid var(--accent);border-radius:6px;padding:.7rem .9rem .8rem;position:relative;}
.focus[hidden]{display:none;}
.focus .x{position:absolute;top:.5rem;right:.6rem;background:none;border:1px solid var(--line);
  color:var(--sub);border-radius:3px;cursor:pointer;font-size:.72rem;padding:.1em .5em;font-family:inherit;}
.focus .ft{font-size:.95rem;padding-right:5rem;}
.focus .ft .id{font-family:var(--mono);color:var(--accent);margin-right:.5em;}
.focus .crit{font-size:.8rem;color:var(--sub);margin-top:.3rem;}
.focus h3{font-size:.68rem;text-transform:uppercase;letter-spacing:.06em;color:var(--sub);margin:.6rem 0 .15rem;}
.fcols{display:grid;grid-template-columns:1fr 1fr;gap:.9rem;}
@media (max-width:520px){.fcols{grid-template-columns:1fr;}}
.focus li{white-space:normal;cursor:default;font-size:.82rem;}
.focus li .id{font-family:var(--mono);font-size:.78em;color:var(--sub);flex:none;width:3.6em;}
.focus li.done{color:var(--sub);}
.focus li.none{color:var(--sub);font-size:.78rem;}
.meta{display:flex;gap:1.2rem;flex-wrap:wrap;font-size:.78rem;color:var(--sub);}
.note{font-size:.8rem;color:var(--sub);margin:0;}
code{font-family:var(--mono);font-size:.85em;}
</style>
<main>
<header>
  <h1>harness 着手順ボード</h1>
  <p>__SOURCES__ の next-directions.md のスナップショット(__GENERATED__)。
  <code>render-board.sh v__VERSION__</code> が <code>nd-tasks.sh --format json</code> から生成。</p>
</header>

<div class="tiles">
__TILES__
</div>

<div class="focus" id="focus" hidden></div>

<div class="boards">
__BOARDS__
</div>

<div class="meta">__META__</div>

<p class="note">__NOTE__</p>
</main>
<script type="application/json" id="board-data">__DATA__</script>
<script>
(function(){
  "use strict";
  // データはページに埋め込んである(CSP 下でも file:// でも外部読み込みは死ぬため)。
  var D = JSON.parse(document.getElementById("board-data").textContent);
  if (!D.archived) D.archived = {};   // 埋め込み側と揃っている前提だが、undefined で全滅させない
  var by = {}, up = {}, down = {}, rows = {}, cur = null;
  D.items.forEach(function(it){ by[it.id] = it; });
  D.edges.forEach(function(e){
    (up[e.from] = up[e.from] || []).push(e.to);     // from は to に依存 = to が上流
    (down[e.to] = down[e.to] || []).push(e.from);
  });
  // 推移閉包(幅優先)。seen で循環を止めるので、正典に循環が書かれても固まらない。
  function closure(map, id){
    var seen = {}, out = [], q = (map[id] || []).slice();
    while (q.length){
      var n = q.shift();
      if (seen[n]) continue;
      seen[n] = 1; out.push(n);
      (map[n] || []).forEach(function(x){ if (!seen[x]) q.push(x); });
    }
    return out;
  }
  var panel = document.getElementById("focus");
  function el(tag, cls, text){
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;   // textContent なのでエスケープの心配が要らない
    return n;
  }
  function list(ids, empty){
    var ul = document.createElement("ul");
    if (!ids.length){ ul.appendChild(el("li", "none", empty)); return ul; }
    ids.forEach(function(id){
      // 解決は**行のバッジと同じ3値**(着手順 → 完了記録 → どこにも無い)。ここだけ
      // 「着手順に無い」で止めると、⇐ H-3 ✔ をクリックした人に矛盾した答えを返すことになる。
      var it = by[id];
      var arch = Object.prototype.hasOwnProperty.call(D.archived, id) ? D.archived[id] : null;
      var done = (it && it.status === "done") || (!it && arch !== null);
      var li = el("li", done ? "done" : null);
      li.appendChild(el("span", "id", id));
      li.appendChild(el("span", "t", it ? it.title
        : (arch !== null ? "(完了記録にあり" + (arch ? " " + arch : "") + ")"
                         : "(参照先なし — 着手順にも完了記録にも無い)")));
      if (done) li.appendChild(el("span", "dep past", "済"));
      else if (!it) li.appendChild(el("span", "dep gone", "?"));
      ul.appendChild(li);
    });
    return ul;
  }
  function clear(){
    Object.keys(rows).forEach(function(k){ rows[k].className = rows[k].getAttribute("data-cls"); });
  }
  function hide(){ clear(); panel.hidden = true; cur = null; }
  function show(id){
    if (cur === id){ hide(); return; }          // もう一度クリックで解除
    cur = id; clear();
    var u = closure(up, id), d = closure(down, id);
    panel.textContent = "";
    var x = el("button", "x", "✕ 閉じる"); x.addEventListener("click", hide);
    panel.appendChild(x);
    var t = el("div", "ft");
    t.appendChild(el("span", "id", id));
    t.appendChild(el("span", null, by[id] ? by[id].title : id));
    panel.appendChild(t);
    panel.appendChild(el("div", "crit", "完了条件: " + ((by[id] && by[id].criteria) || "(未記載)")));
    if (!u.length && !d.length){
      panel.appendChild(el("div", "crit", "依存なし(着手可能)"));
    } else {
      var cols = el("div", "fcols"), a = el("div"), b = el("div");
      a.appendChild(el("h3", null, "上流 — これを塞いでいるもの"));
      a.appendChild(list(u, "なし(これを塞いでいるものは無い)"));
      b.appendChild(el("h3", null, "下流 — これが解けると着手可能になるもの"));
      b.appendChild(list(d, "なし(これを待っている項目は無い)"));
      cols.appendChild(a); cols.appendChild(b);
      panel.appendChild(cols);
    }
    panel.hidden = false;
    if (rows[id]) rows[id].className += " sel";
    u.forEach(function(n){ if (rows[n]) rows[n].className += " hl-up"; });
    d.forEach(function(n){ if (rows[n]) rows[n].className += " hl-down"; });
  }
  Array.prototype.forEach.call(document.querySelectorAll("li[data-id]"), function(li){
    var id = li.getAttribute("data-id");
    rows[id] = li;
    li.setAttribute("data-cls", li.className);   // 元の class を控えておき、解除時に戻す
    li.addEventListener("click", function(){ show(id); });
  });
  document.addEventListener("keydown", function(e){ if (e.key === "Escape") hide(); });
})();
</script>
</html>
"""

out = (TEMPLATE
       .replace("__VERSION__", html.escape(VERSION))
       .replace("__SOURCES__", html.escape(srcs or "(不明)"))
       .replace("__GENERATED__", generated)
       .replace("__TILES__", "\n".join(tiles))
       .replace("__BOARDS__", "\n".join(board_html))
       .replace("__META__", meta_line)
       .replace("__NOTE__", note)
       .replace("__DATA__", data_json))

# 一時ファイル + os.replace(同一ディレクトリなので atomic)。ブラウザが開いたまま
# 再生成しても、半分だけ書かれた HTML を読ませない(nd-tasks.sh の書き込みと同じ流儀)。
# 一時名に PID を入れるのは、2つの render-board.sh が同時に同じ出力先へ走ったときに
# 一時ファイル同士が潰し合わないため(最後に replace した方が勝つのは構わない ——
# **どちらも完全な HTML** なので、混ざった中間状態だけを避ければよい)。
abs_out = os.path.abspath(OUT_PATH)
tmp_out = "%s.%d.tmp" % (abs_out, os.getpid())
try:
    with open(tmp_out, "w", encoding="utf-8") as fp:
        fp.write(out)
    os.replace(tmp_out, abs_out)
except OSError as e:
    # traceback を投げると呼び出し側(将来の post-commit hook)のログが読めなくなる。
    try:
        os.unlink(tmp_out)
    except OSError:
        pass
    sys.stderr.write("✗ 出力に失敗した: %s (%s)\n" % (abs_out, e))
    sys.exit(2)
# stdout はこの1行だけ。`open "$(render-board.sh)"` が成立する契約なので**絶対パス**で出す
# (-o に相対パスを渡されたときも、呼び出し側の cwd に依存しない答えを返す)。
print(abs_out)
PY

BOARD_JSON="$tmp/tasks.json" \
BOARD_OUT="$OUT" \
BOARD_BRANCHES="$tmp/branches" \
BOARD_VERSION="$VERSION" \
BOARD_WARN_CHARS="$HEAD_WARN_CHARS" \
BOARD_WARN_TOKENS="$HEAD_WARN_TOKENS" \
BOARD_HARD_CHARS="$HEAD_HARD_CHARS" \
BOARD_BASE="${BASE:-}" \
  python3 "$tmp/render.py"
