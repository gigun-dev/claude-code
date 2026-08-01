#!/usr/bin/env bash
# sim-shot.sh — 起動済み iOS Simulator のスクリーンショットを撮り、座標空間を毎回 JSON で返す。
#
# Why: スクショは pixels、idb ui tap は points。この2空間の食い違いが「撮った画像の座標で
# タップしたのにズレる」問題の根源。Anthropic の Desktop ツールはスクショと一緒に
# "Coordinate space for screenshot/tap/swipe: {W}x{H} pixels (origin top-left)." を毎回返して
# 食い違いを消している。ここではそれを再現し、さらに point 実寸と scale も出して
# 「pixel 座標 ÷ scale = point 座標(= idb ui tap に渡す値)」を機械的に導けるようにする。
#
# Why stdout は JSON(2026-08-02 変更): 旧版は人間向けテキストを stdout に流していたが、
#   実走行でエージェントが "Coordinate space ..." の散文を読み違えて px のままタップした。
#   公式ガイド(docs/skill-creation/using-scripts.mdx「Use structured output」)の通り
#   **データは stdout に JSON / 診断は stderr** に分ける。散文の強調では崖から落ちる経路が残る。
#   ボツ案: --json フラグで切り替える → 既定が人間向けだと結局エージェントが散文を読む。
#     このスクリプトの主たる利用者はエージェントなので、既定を JSON にして人間向けは stderr に置く。
#
# Why UDID 必須(2026-08-01 変更・後方互換を意図的に壊した):
#   旧版は `xcrun simctl io booted screenshot` 決め打ちで UDID を受け取れなかった。
#   実地(booted 4台の日)でこれを呼んだところ **別エージェントが作業中の端末を撮ってしまった**。
#   読み取り専用だったので実害は無かったが、「触らない約束の端末に触った」という事故そのもの。
#   simctl の `booted` は「Booted な端末が1台だけならそれ、複数なら不定」という危険な糖衣なので、
#   このスキルの全スクリプトは --udid か SIM_UDID を必須にして、
#   「省略したら暗黙に何かへ飛ぶ」経路を構造的に塞ぐ。
#   ボツ案: 未指定時に「Booted が1台だけなら自動でそれを使う」フォールバック
#     → 「今日はたまたま1台だった」ときに動いてしまい、2台になった日に静かに誤爆する。
#
# Why 出力先の既定が $HOME 配下:
#   エージェント実行環境の sandbox は /tmp 配下への書き込みを弾く
#   (NSCocoaErrorDomain code=642 "the volume ... is read only")。simctl 側の権限問題ではないので
#   sudo でも Simulator 再起動でも直らない。セッション用 scratchpad が /tmp 配下にある場合も同じ。
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sim-shot.sh --udid <UDID> [OUT.png]

指定した Simulator のスクリーンショットを撮り、座標空間(pixels / points / scale)を
JSON で stdout に返す。人間向けの警告・診断は stderr。

Options:
  --udid <UDID>   対象 Simulator の UDID(必須。環境変数 SIM_UDID でも可)
  OUT.png         出力パス(既定: ~/tmp-sim/sim-shot-<UNIX時刻>.png)
  -h, --help      このヘルプ

Output (stdout, JSON):
  {"status":"ok","path":"...","udid":"...","pixel_size":[1206,2622],
   "point_size":[402,874],"scale":3,"hint":"point = pixel / scale"}
  ※ idb が無い/前面にアプリがいない場合は point_size と scale が null になる(撮影自体は成功)。

Exit codes (このスキルの全スクリプト共通):
  0  成功
  2  引数不正(--udid 未指定など)
  3  端末が見つからない / Booted でない / simctl 失敗
  4  要素が見つからない        (このスクリプトでは未使用)
  5  タイムアウト              (このスクリプトでは未使用)
  6  idb 未導入 / companion 未接続 / idb 実行失敗(このスクリプトでは警告どまり)
  7  前提不足(外部ツール・ファイル不在、書き込み不可)

Examples:
  scripts/sim-shot.sh --udid EF5D841C-...
  SIM_UDID=EF5D841C-... scripts/sim-shot.sh ~/tmp-sim/before.png
EOF
}

# ---- 共通の作法(bash 3本で同一実装を意図的に複製している) ---------------------------
# Why not 共通ファイルに切り出す: スキルのスクリプトは1本だけコピーされて他所で使われることが
# あり、相対 source は簡単に壊れる。重複を許して単体完結を優先する(既存の python 3本も同じ方針)。
err() { printf '%s\n' "$@" >&2; }
# JSON 文字列のエスケープ。jq に依存しない(依存ゼロを維持するため)。
# パスに制御文字が入ることは想定していない —— 実用上は \ と " だけで足りる。
json_str() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }
# Booted な端末を "UDID<TAB>名前" で列挙。`simctl list devices booted` の行形式に依存する。
list_booted() {
  xcrun simctl list devices booted 2>/dev/null \
    | sed -n 's/^[[:space:]]*\(.*\) (\([0-9A-Fa-f-]\{20,\}\)) (Booted).*/\2	\1/p'
}
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# describe-all の JSON(stdin)から面積最大の frame(= 画面全体)を "W H"(points)で返す。
#
# Why 一時ファイル経由で uv を呼ぶ(2026-08-02 に修正した実バグ):
#   旧版は `idb ... | uv run --quiet - <<'PY' ... PY` と書いていたが、
#   **ヒアドキュメントが stdin を上書きするのでパイプの中身は Python に届かない**。
#   結果、point/scale は常に取得失敗し、しかも「idb 未接続かも/アプリが前面にいないかも」という
#   見当違いの案内を毎回出していた(= 誤誘導を生むコード)。実測で確認済み:
#   `echo '[...]' | uv run --quiet - <<'PY' sys.stdin.read() PY` は空文字列を読む。
#   uv には「スクリプト = ファイル / データ = stdin」と分けて渡す必要がある。
#   ボツ案: JSON を argv で渡す(`uv run - "$JSON"` は実際に動く)
#     → describe-all は数百KB になりうるので ARG_MAX(macOS は約1MB)に張り付く危険がある。
#   一時ファイルは $HOME 配下に置く(/tmp は sandbox で書き込みを弾かれる)。
max_frame_from_stdin() {
  local py="$HOME/tmp-sim/.sim-maxframe.$$.py" rc
  command -v uv >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$py")" 2>/dev/null || return 1
  cat > "$py" <<'PY'
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
# describe-all は JSON(配列 or 入れ子) or JSON-lines のどれもあり得るので両対応。
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    data = [json.loads(l) for l in raw.splitlines() if l.strip()]

best = None
def walk(n):
    global best
    if isinstance(n, list):
        for i in n:
            walk(i)
    elif isinstance(n, dict):
        f = n.get("frame")
        if isinstance(f, dict):
            w, h = f.get("width"), f.get("height")
            if isinstance(w, (int, float)) and isinstance(h, (int, float)) and w > 0 and h > 0:
                if best is None or w * h > best[0] * best[1]:
                    best = (w, h)
        for v in n.values():
            walk(v)
walk(data)
if best:
    print(int(round(best[0])), int(round(best[1])))
PY
  uv run --quiet "$py" 2>/dev/null
  rc=$?
  rm -f "$py"
  return "$rc"
}
# ------------------------------------------------------------------------------------

UDID="${SIM_UDID:-}"
OUT=""

# 引数パース。位置引数(出力パス)は旧版と同じ場所に置けるよう維持する
# —— 壊したのは「UDID 省略可」と「stdout の形式」だけで、出力パスの渡し方まで変えない。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="${2:-}"; shift 2 || true ;;
    --udid=*) UDID="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) err "不明なオプション: $1" "  → scripts/sim-shot.sh --help で使い方を確認する。"; exit 2 ;;
    *) OUT="$1"; shift ;;
  esac
done

# エラー復帰の作法: 「失敗した」で止めず必ず次の一手を添える(全スクリプトで同じ文面に揃えてある)。
if [[ -z "$UDID" ]]; then
  err "UDID 未指定。--udid <UDID> か環境変数 SIM_UDID を指定すること。" \
      "  → xcrun simctl list devices booted で対象を確認してから明示する" \
      "    (複数 booted は現実に起きる。実地で4台同時 booted の日があり、'booted' 指定は" \
      "     不定に化けて他人の端末を撮る事故になったため、意図的に必須化している)。" \
      "  → scripts/sim-preflight.sh --udid <UDID> で環境ごと確認するのが早い。"
  exit 2
fi

# xcrun 不在を「端末が見つからない(3)」と誤報しないよう先に切り分ける
# —— 原因が違えば次の一手も違う(boot するのか Xcode を入れるのか)。
if ! command -v xcrun >/dev/null 2>&1; then
  err "xcrun が無い。フル Xcode が必要(Command Line Tools だけでは simctl が揃わない)。" \
      "  → xcode-select -p で選択中の開発者ディレクトリを確認する。"
  exit 7
fi

# Booted 確認を撮影の前に置く: simctl のエラー文面だけだと「UDID の打ち間違い」と
# 「端末が落ちている」の区別がつかず、実地で切り分けに時間を溶かしたため。
BOOTED="$(list_booted || true)"
if ! printf '%s\n' "$BOOTED" | tr '[:lower:]' '[:upper:]' | grep -qF "$(upper "$UDID")"; then
  err "UDID '$UDID' は Booted な端末として見つからない。" \
      "  → 現在 Booted な端末:" \
      "${BOOTED:-    (なし)}" \
      "  → 起動するなら xcrun simctl boot \"$UDID\"(他人が使っている端末を落とさないこと)。"
  exit 3
fi

OUT="${OUT:-$HOME/tmp-sim/sim-shot-$(date +%s).png}"

# /tmp 配下は sandbox に弾かれる。撮ってから 642 で落ちると原因が分かりにくいので先に言う。
case "$OUT" in
  /tmp/*|/private/tmp/*)
    err "警告: 出力先 '$OUT' は /tmp 配下。sandbox 下では書き込みが弾かれる(code=642)ことがある。" \
        "  → 弾かれたら ~/tmp-sim/ に撮ってから mv すること。"
    ;;
esac

if ! mkdir -p "$(dirname "$OUT")" 2>/dev/null; then
  err "出力ディレクトリを作れない: $(dirname "$OUT")" "  → ~/tmp-sim/ 配下を指定してリトライ。"
  exit 7
fi

# simctl 単体で撮れる(idb 不要)。
# 旧版は stderr を /tmp/sim-shot.err に落としていたが、それ自体が上記の /tmp 書込み制約に
# 引っかかる自己矛盾だったので、変数に受けるように変えた。
if ! ERRTXT="$(xcrun simctl io "$UDID" screenshot "$OUT" 2>&1)"; then
  err "screenshot に失敗(UDID=$UDID)。" \
      "  → 'volume is read only' なら出力先が /tmp 配下。~/tmp-sim/ に撮り直す。" \
      "  → 端末が落ちた可能性: xcrun simctl list devices booted で再確認。" \
      "$ERRTXT"
  exit 3
fi

# pixel 実寸は sips(macOS 標準・依存ゼロ)で読む。
# 別解: `xcrun simctl io <UDID> enumerate` の "Default width/height" でも取れる(実測)。
# sips を採ったのは「実際に保存された画像そのもの」を測るため —— enumerate はデバイスの
# 公称値なので、将来スケール指定つきの撮影が入ったときに実ファイルと食い違いうる。
PXW=$(sips -g pixelWidth  "$OUT" | awk '/pixelWidth/{print $2}')
PXH=$(sips -g pixelHeight "$OUT" | awk '/pixelHeight/{print $2}')

# point 実寸と scale は idb のアクセシビリティ・ルート frame(points)から導く。
# idb が無ければ scale 不明として pixel だけ返す(screenshot 自体は成立しているので致命ではない)。
PTW="" ; PTH="" ; SCALE=""
if command -v idb >/dev/null 2>&1; then
  # 面積最大の frame = 画面全体(ルート)とみなす(describe-all は入れ子で返ることもあるので再帰で舐める)。
  RECT="$(idb ui describe-all --udid "$UDID" --json 2>/dev/null | max_frame_from_stdin || true)"
  read -r PTW PTH <<<"${RECT:-}"
  if [[ -n "${PTW:-}" && "${PTW:-0}" -gt 0 ]]; then
    # scale = pixel幅 / point幅(Retina は 2 or 3)。%.3g で 3 / 2 のような整数表記に落ちる。
    SCALE=$(awk -v p="$PXW" -v q="$PTW" 'BEGIN{printf "%.3g", p/q}')
  fi
fi

if [[ -n "${SCALE:-}" ]]; then
  printf '{"status":"ok","path":%s,"udid":%s,"pixel_size":[%s,%s],"point_size":[%s,%s],"scale":%s,"hint":"point = pixel / scale"}\n' \
    "$(json_str "$OUT")" "$(json_str "$UDID")" "$PXW" "$PXH" "$PTW" "$PTH" "$SCALE"
  err "saved: $OUT (${PXW}x${PXH} px / ${PTW}x${PTH} pt / scale=${SCALE})" \
      "  → idb ui tap に渡すのは points。ラベルや AXUniqueId が分かるなら sim-tap.py / sim-nav.py を使い、手で割り算しないこと。"
else
  printf '{"status":"ok","path":%s,"udid":%s,"pixel_size":[%s,%s],"point_size":null,"scale":null,"hint":"point size unknown; see stderr"}\n' \
    "$(json_str "$OUT")" "$(json_str "$UDID")" "$PXW" "$PXH"
  if command -v idb >/dev/null 2>&1; then
    # ここが「idb はあるのに point 幅が取れなかった」= 面積 0 しか無かったケース。
    # 実地ではこれの正体はほぼ **describe-all が frame:{0,0,0,0} の1要素しか返していない**、
    # つまり「対象アプリが前面にいない」印(FEEDBACK 2026-08-01 §2 の実測)。
    # 旧版はここも一律「idb 未接続」と案内していたが、それは誤誘導 —— この一言が無かったせいで
    # 「AX/HID が壊れた」と誤診して shutdown→boot まで走った例がある。切り分けの一手を明示する。
    err "注意: idb はあるが point 実寸を取得できなかった(describe-all が空 or frame 全部 0)。" \
        "  → これは AX/HID の故障とは限らない。まず『対象アプリが前面にいない』を疑う:" \
        "    xcrun simctl launch --terminate-running-process $UDID <bundle-id> して数秒待ってからリトライ。" \
        "  → それでも駄目なら companion 接続を確認: idb list-targets / idb connect $UDID"
  else
    err "注意: idb 未導入のため point/scale 不明。" \
        "  → uv tool install fb-idb → idb connect $UDID 後に再実行するか、sim-tap.py でラベル指定タップを使う。"
  fi
fi
