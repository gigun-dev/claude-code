#!/usr/bin/env bash
# harness-template v0.1.0 (配布元: gigun-dev/claude-code plugins/harness)
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
# 【依存(新規に増やさない)】
#   bash + python3 + git。python3 は verify.sh・doctor が既に必須にしているので追加負担は無い。
#   ⚠️ python3 が無い環境では**黙って劣化させず落とす**(原則4。「検査できなかった」を
#      「合格」にしないのと同じで、「描けなかった」を「空のボード」にしない)。
set -euo pipefail

VERSION="0.1.0"
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
  ⇐ X      = X に依存と書かれているが、X は着手順に無い(アーカイブ済み or 散文中の例)。
             blocked には数えない
  ⎇ name   = --branches 指定時のみ。その ID に言及する未マージのコミットがあるブランチ
  行をクリック = focus。上流(これを塞いでいるもの)と下流(これが解けると動くもの)を
             推移的に出す。もう一度クリック / Esc / ✕ で解除。全域グラフは描かない。
  各ボードの下に「現在地」とカタログ目次を <details>(既定閉)で畳んである。

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
BASE_BRANCH = os.environ.get("BOARD_BASE", "")

def warn(msg):
    """診断は必ず stderr へ。stdout はパス1行だけという契約を壊さない。"""
    sys.stderr.write("⚠ %s\n" % msg)

with open(JSON_PATH, encoding="utf-8") as fp:
    data = json.load(fp)
items = data.get("items", [])
files = data.get("files", [])

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

# 辺の3分類。**捨てずに分ける**のが要点:
#   blocking … 相手が着手順にいて未完了 → これだけが blocked を作る
#   settled  … 相手が着手順にいて完了済み → 情報としては出すが blocked にしない
#   dangling … 相手が着手順に居ない。アーカイブ済みか、**散文中の例**(実例: H-15 の
#              本文にある `→ 依存: H-3` は「こういう書式を導入する」という説明であって
#              実在の依存ではない)。blocked にはしないが、**黙って捨てもしない** ——
#              捨てると「辺が2本のはずが1本しか出ない」ときに気づけなくなる。
blocking, settled, dangling = [], [], []
for f, t in edges_all:
    tgt = by_id.get(t)
    if tgt is None:
        dangling.append((f, t))
    elif tgt.get("status") == "open":
        blocking.append((f, t))
    else:
        settled.append((f, t))

blocked_by = {}
for f, t in blocking:
    blocked_by.setdefault(f, []).append(t)
other_deps = {}
for f, t in settled + dangling:
    other_deps.setdefault(f, []).append(t)

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
# ND から「現在地」とカタログ目次を切り出す
# =============================================================================
# **抽出できなかったときに空を出さない**のが唯一の要件(原則4)。ND の構成は配布先ごとに
# 揺れるので、想定と違う形は必ずあるものとして扱い、「無かった」ではなく
# 「(抽出できず: 理由)」を画面に出す —— 空欄は「現在地が書かれていない」と読まれてしまう。
MISSING = "抽出できず"

def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fp:
            return fp.read().split("\n")
    except OSError as e:
        warn("ND が読めない: %s (%s)" % (path, e))
        return None

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

# --- 行 -----------------------------------------------------------------------
def badge(cls, text, tip):
    return '<span class="%s" title="%s">%s</span>' % (cls, html.escape(tip), html.escape(text))

def render_row(it, is_next):
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
    for t in other_deps.get(it["id"], []):
        if t in by_id:
            parts.append(badge("dep past", "⇐ %s" % t, "%s に依存。%s は完了済みなので blocked ではない" % (t, t)))
        else:
            parts.append(badge("dep past", "⇐ %s" % t, "%s に依存と書かれているが、%s は着手順に無い(アーカイブ済み、または散文中の例)。blocked には数えない" % (t, t)))
    for br in branches.get(it["id"], []):
        parts.append(badge("br", "⎇ %s" % br, "%s に言及する未マージのコミットが %s にある" % (it["id"], br)))
    return '<li%s data-id="%s" title="%s">%s</li>' % (
        (' class="%s"' % " ".join(cls)) if cls else "",
        html.escape(it["id"]),
        html.escape(full),
        "".join(parts),
    )

board_html = []
for b in boards:
    rows = "\n".join(render_row(it, it["id"] == b["next"]) for it in b["items"])
    lines = read_lines(b["file"]) if b["file"] else None
    now_html, now_note = section_now(lines)
    if now_note:
        warn("%s: %s" % (b["name"], now_note))
        now_html = '<p class="missing">(注意: %s)</p>' % html.escape(now_note) + now_html
    toc_html = section_toc(lines)
    meta = b["meta"]
    size = ""
    if meta.get("head_chars") is not None:
        over = meta["head_chars"] > WARN_CHARS or meta.get("head_tokens_est", 0) > WARN_TOKENS
        size = '<span%s>頭 %s字 / ≒%s tok%s</span>' % (
            ' class="over"' if over else "",
            meta["head_chars"], meta.get("head_tokens_est", "?"),
            # 超過しているときだけ予算を併記する。予算内のときに毎回「/ 8000字」まで出すと、
            # 一覧の中で最も情報量の少ない数字が最も目立つ場所を占める。
            "(予算 %d字 / %d tok 超過)" % (WARN_CHARS, WARN_TOKENS) if over else "")
    board_html.append(
        '<div class="board"><h2>%s <span>%d件</span></h2>\n<ul>\n%s\n</ul>\n'
        '<div class="extra">%s'
        '<details><summary>現在地</summary><div class="body">%s</div></details>'
        '<details><summary>カタログ目次(本文は ND を Read / grep)</summary><div class="body">%s</div></details>'
        "</div></div>"
        % (html.escape(b["name"]), len(b["items"]), rows,
           ('<div class="size">%s</div>' % size) if size else "", now_html, toc_html)
    )

# --- タイル -------------------------------------------------------------------
n_open = sum(1 for it in items if it.get("status") == "open")
n_done = len(items) - n_open
n_over = sum(1 for f in files
             if f.get("head_chars", 0) > WARN_CHARS or f.get("head_tokens_est", 0) > WARN_TOKENS)

tiles = []
for b in boards:
    if b["next"]:
        nxt = by_id[b["next"]]
        label = "%s %s" % (b["next"], plain(nxt.get("summary")))
    else:
        label = "なし(全て blocked か完了)"
    tiles.append('<div class="tile next"><div class="k">次(%s)</div><div class="v" title="%s">%s</div></div>'
                 % (html.escape(b["name"]), html.escape(label), html.escape(label)))
tiles.append('<div class="tile"><div class="k">未完了</div><div class="v">%d <small>/ 完了 %d</small></div></div>'
             % (n_open, n_done))
dep_small = "blocked %d" % len(blocked_by)
if dangling:
    dep_small += " / 参照先なし %d" % len(dangling)
if settled:
    dep_small += " / 解決済み %d" % len(settled)
tiles.append('<div class="tile%s"><div class="k">依存辺(自由文)</div><div class="v">%d <small>%s</small></div></div>'
             % (" warn" if blocked_by else "", len(edges_all), dep_small))
tiles.append('<div class="tile%s"><div class="k">頭サイズ</div><div class="v">%s</div></div>'
             % (" warn" if n_over else "",
                ("%d件 超過" % n_over) if n_over else "予算内"))

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
}
data_json = json.dumps(focus_data, ensure_ascii=False).replace("<", "\\u003c")

generated = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
srcs = ", ".join(sorted(set(os.path.basename(os.path.dirname(f.get("file", ""))) or "?" for f in files)))

meta_line = (
    '<span>■ = 次(blocked でない最初の未完了)</span>'
    '<span>☐ = 未完了(上から着手順)</span><span>✔ = 完了</span>'
    '<span>⇠ X 待ち = X(未完了)に依存 → 着手できない</span>'
    '<span>⇐ X = X に依存(X は着手順に無い / 完了済み)—— blocked に数えない</span>'
)
if branches:
    meta_line += '<span>⎇ = %s に未マージのコミットがあるブランチ</span>' % html.escape(BASE_BRANCH or "基準ブランチ")
meta_line += '<span>行をクリック → 上流/下流(Esc で解除)</span>'

note = (
    "構造の実体は「コンポーネント → 順序付きリスト」の2層で、木ではない。順序は位置が運び、"
    "依存は自由文から %d 本だけ抽出できる(機械可読フィールドは 0。<code>H-15</code> が入ったら "
    "<code>render-board.sh</code> の <code>extract_edges()</code> だけを差し替える)。"
    "全域グラフを描かないのは、29項目のノードが画面に収まらず順序が消えるのを実測したため —— "
    "近傍が要るときは行をクリックする。"
) % len(edges_all)
if dangling:
    note += (
        " 参照先が着手順に無い辺が %d 本ある(%s)—— アーカイブ済みか、書式の説明として"
        "本文に書かれた例。blocked には数えないが、捨てずに <code>⇐</code> で出している。"
    ) % (len(dangling), html.escape(", ".join("%s→%s" % (f, t) for f, t in dangling)))

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
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:.6rem;}
.tile{background:var(--card);border:1px solid var(--line);border-radius:5px;padding:.55rem .85rem;overflow:hidden;}
.tile .k{font-size:.66rem;letter-spacing:.07em;text-transform:uppercase;color:var(--sub);}
.tile .v{font-size:1.05rem;font-variant-numeric:tabular-nums;margin-top:.1rem;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.tile .v small{font-size:.72rem;color:var(--sub);font-weight:400;}
.tile.next .v{color:var(--accent);font-family:var(--mono);font-size:.95rem;}
.tile.warn .v{color:var(--warn);}
.boards{display:grid;grid-template-columns:repeat(auto-fit,minmax(460px,1fr));gap:1rem;align-items:start;}
@media (max-width:520px){.boards{grid-template-columns:1fr;}}
.board{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:.65rem .9rem .8rem;}
.board h2{font-size:.78rem;letter-spacing:.06em;color:var(--sub);margin:.1rem 0 .45rem;
  text-transform:uppercase;display:flex;justify-content:space-between;}
.board h2 span{font-variant-numeric:tabular-nums;}
ul{list-style:none;margin:0;padding:0;font-size:.86rem;}
li{display:flex;align-items:baseline;gap:.55em;padding:.13rem 0;white-space:nowrap;}
.board > ul > li{cursor:pointer;border-radius:3px;}
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
.br{font-family:var(--mono);font-size:.72em;color:var(--sub);border:1px dashed var(--line);
  border-radius:3px;padding:0 .35em;margin-left:.3em;flex:none;}
/* focus 中の強調。色は既存トークンの上に薄い面を敷くだけで、両テーマで破綻しない値にした。 */
li.sel{outline:1px solid var(--accent);}
li.hl-up{background:rgba(176,130,31,.14);}
li.hl-down{background:rgba(62,124,79,.14);}
.extra{margin-top:.6rem;border-top:1px solid var(--line);padding-top:.4rem;}
.extra .size{font-size:.7rem;color:var(--sub);font-variant-numeric:tabular-nums;margin-bottom:.25rem;}
.extra .size .over{color:var(--warn);}
details{font-size:.8rem;margin-top:.2rem;}
details summary{cursor:pointer;color:var(--sub);font-size:.7rem;letter-spacing:.05em;text-transform:uppercase;}
details .body{margin-top:.35rem;}
details .body p{margin:.3rem 0;}
details .body p.q{color:var(--sub);border-left:2px solid var(--line);padding-left:.5em;}
details .body p.sub{font-weight:600;}
details .body ul{list-style:disc;padding-left:1.15em;}
details .body li{display:list-item;white-space:normal;cursor:default;padding:.08rem 0;}
details .body ul.toc li{list-style:none;font-family:var(--mono);font-size:.75em;color:var(--sub);}
details .body ul.toc li.h3{padding-left:1.1em;}
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
      var it = by[id], li = el("li", it && it.status === "done" ? "done" : null);
      li.appendChild(el("span", "id", id));
      li.appendChild(el("span", "t", it ? it.title : "(着手順に無い — アーカイブ済みか散文中の例)"));
      if (it && it.status === "done") li.appendChild(el("span", "dep past", "済"));
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
BOARD_BASE="${BASE:-}" \
  python3 "$tmp/render.py"
