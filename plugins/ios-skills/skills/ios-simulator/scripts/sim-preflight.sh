#!/usr/bin/env bash
# sim-preflight.sh — 観測を始める前の環境チェックを1コマンドに畳む。
#
# Why: SKILL.md の「★事前チェック」は4項目の手順として書いてあるが、**実走行で飛ばされた**。
#   飛ばした結果、(a) ソフトキーボードが出ない設定のまま入力系の観測を続けて誤診に至る、
#   (b) システムプロキシに TLS を全部落とされて「サーバーが落ちている」と誤読する、
#   という時間の溶かし方をしている。散文の手順は narrow bridge —— 崖から落ちる経路が残る。
#   公式ガイド(best-practices.mdx「Set appropriate degrees of freedom」)の通り、
#   壊れやすい前提確認は low-freedom なスクリプトに倒す。
#
# Why stdout は常に JSON: エージェントが機械的に分岐できる形が要る。各 warning には
#   **そのまま実行できる fix コマンド**を入れてある(読んだ次のターンで直せる)。
#   人間向けの要約は stderr に出すので、--human のような切替フラグは持たせない。
#
# Why `set -e` を使わない: 事前チェックは「壊れているところを全部数え上げる」のが仕事。
#   最初の失敗で abort したら、他の問題が見えないまま1つずつ直す往復になる。
#   個々の probe は失敗を値(unknown)として扱い、最後にまとめて判定する。
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: sim-preflight.sh --udid <UDID>

観測を始める前の環境チェック(端末の状態・キーボード設定・システムプロキシ・idb 接続・
座標スケール)をまとめて実行し、結果を JSON で stdout に返す。人間向け要約は stderr。

Options:
  --udid <UDID>   対象 Simulator の UDID(必須。環境変数 SIM_UDID でも可)
  --no-scale      スケール計測(スクショ+describe-all)を省いて高速化
  -h, --help      このヘルプ

Output (stdout, JSON):
  {"udid":"...","booted":true,"ok":false,
   "booted_devices":[{"udid":"...","name":"iPhone 16 Pro"}],
   "idb":{"cli":true,"companion_connected":true},
   "keyboard":{"connect_hardware_keyboard":true},
   "proxy":{"system_https_proxy":"127.0.0.1:9090","capture_processes":["Proxyman"]},
   "processes":{"xcodebuild":0},
   "pixel_size":[1206,2622],"point_size":[402,874],"scale":3,
   "warnings":[{"id":"system_proxy_active","severity":"warn","detail":"...","fix":"<コマンド>"}]}
  warnings[].fix には**そのまま実行できるコマンド**が入っている。

Exit codes:
  0  すべて問題なし(ok=true)
  1  JSON は正常に出したが警告あり(ok=false。warnings を読んで fix を実行する)
  2  引数不正(--udid 未指定など)
  3  指定 UDID が Booted でない / 見つからない
  7  前提不足(xcrun が無い等。preflight 自体が成立しない)
  ※ 4/5/6(要素なし・タイムアウト・idb)はここでは使わない。idb の不備は「警告」として
     JSON に載せる(preflight 自体は成立するため)。

Examples:
  scripts/sim-preflight.sh --udid EF5D841C-...
  SIM_UDID=EF5D841C-... scripts/sim-preflight.sh --no-scale
EOF
}

# ---- 共通の作法(bash 3本で同一実装を意図的に複製。単体でコピーされても動くことを優先) ----
err() { printf '%s\n' "$@" >&2; }
json_str() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }
list_booted() {
  xcrun simctl list devices booted 2>/dev/null \
    | sed -n 's/^[[:space:]]*\(.*\) (\([0-9A-Fa-f-]\{20,\}\)) (Booted).*/\2	\1/p'
}
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# describe-all の JSON(stdin)から面積最大の frame(= 画面全体)を "W H"(points)で返す。
# Why 一時ファイル経由で uv を呼ぶ: `... | uv run --quiet - <<'PY'` はヒアドキュメントが stdin を
#   上書きするため **パイプの中身が Python に届かない**(2026-08-02 実測。旧 sim-shot.sh の
#   scale 表示はこの理由で常に失敗し、しかも「idb 未接続かも」という誤った案内を出していた)。
#   uv には「スクリプト = ファイル / データ = stdin」と分けて渡す。一時ファイルは $HOME 配下
#   (/tmp は sandbox で書き込みを弾かれる)。
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

# 外部コマンドの無限待ちを潰す。macOS には coreutils の timeout(1) が無いのでバックグラウンド
# 起動 + kill -0 のポーリングで代用する。エージェントは非対話シェルなので、
# ハングは「セッションごと詰まる」最悪の失敗になる(実際 idb は companion が死ぬと固まる)。
run_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$! i=0
  local limit=$(( secs * 10 ))   # 0.1s 刻みでポーリングする
  while kill -0 "$pid" 2>/dev/null; do
    if (( i >= limit )); then
      kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    i=$(( i + 1 ))
  done
  wait "$pid"
}

# 警告の蓄積。1要素 = 完成した JSON オブジェクト文字列。
WARNINGS=()
add_warn() { # add_warn <id> <severity> <detail> <fix>
  WARNINGS+=("$(printf '{"id":%s,"severity":%s,"detail":%s,"fix":%s}' \
    "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$3")" "$(json_str "$4")")")
  err "warn[$2] $1: $3" "  fix: $4"
}
join_json() { local IFS=,; printf '%s' "$*"; }
# ------------------------------------------------------------------------------------

UDID="${SIM_UDID:-}"
WANT_SCALE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="${2:-}"; shift 2 || true ;;
    --udid=*) UDID="${1#*=}"; shift ;;
    --no-scale) WANT_SCALE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "不明な引数: $1" "  → scripts/sim-preflight.sh --help で使い方を確認する。"; exit 2 ;;
  esac
done

if [[ -z "$UDID" ]]; then
  err "UDID 未指定。--udid <UDID> か環境変数 SIM_UDID を指定すること。" \
      "  → xcrun simctl list devices booted で対象を確認してから明示する" \
      "    (複数 booted は現実に起きる。実地で4台同時 booted の日があった)。"
  exit 2
fi

# xcrun が無ければ preflight 自体が成立しない(全項目 unknown になる)。ここだけは即死させる。
if ! command -v xcrun >/dev/null 2>&1; then
  err "xcrun が無い。フル Xcode が必要(Command Line Tools だけでは simctl が揃わない)。" \
      "  → xcode-select -p で選択中の開発者ディレクトリを確認する。"
  exit 7
fi

# ---- 1) Booted な端末の一覧と、指定 UDID が Booted か -------------------------------
BOOTED_RAW="$(list_booted)"
BOOTED_JSON=()
BOOTED_COUNT=0
TARGET_BOOTED=false
TARGET_NAME=""
while IFS=$'\t' read -r u n; do
  [[ -z "${u:-}" ]] && continue
  BOOTED_COUNT=$(( BOOTED_COUNT + 1 ))
  BOOTED_JSON+=("$(printf '{"udid":%s,"name":%s}' "$(json_str "$u")" "$(json_str "$n")")")
  if [[ "$(upper "$u")" == "$(upper "$UDID")" ]]; then
    TARGET_BOOTED=true
    TARGET_NAME="$n"
  fi
done <<< "$BOOTED_RAW"

if [[ "$TARGET_BOOTED" != true ]]; then
  add_warn "udid_not_booted" "block" \
    "指定 UDID '$UDID' は Booted な端末として見つからない(Booted は ${BOOTED_COUNT} 台)。" \
    "xcrun simctl boot \"$UDID\"   # 他人が使っている端末を落とさないこと"
fi
# 複数 Booted は「事故が起きる条件が揃っている」印。落とせとは言わない(他人の作業端末かもしれない)。
# 言うべきは「宛先を固定しろ」。実走行の事故は全部『宛先が曖昧なまま撃った』が原因。
if (( BOOTED_COUNT > 1 )); then
  add_warn "multiple_booted_devices" "warn" \
    "Booted な端末が ${BOOTED_COUNT} 台ある。'booted' 指定や UDID 省略は不定の端末へ飛ぶ。" \
    "export SIM_UDID=$UDID   # 以降のスクリプトは全部これを使う"
fi

# ---- 2) 同じ端末を掴みに来る他プロセス ---------------------------------------------
# ps aux | grep xcodebuild と同義。pgrep なら自分自身の grep 行を拾わない。
XCODEBUILD_PIDS="$(pgrep -f xcodebuild 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
XCODEBUILD_COUNT=0
if [[ -n "$XCODEBUILD_PIDS" ]]; then
  XCODEBUILD_COUNT=$(printf '%s' "$XCODEBUILD_PIDS" | wc -w | tr -d ' ')
  add_warn "xcodebuild_running" "warn" \
    "xcodebuild が動いている(pid: $XCODEBUILD_PIDS)。同じ端末を掴んでいると install/launch や UI 操作が競合する。" \
    "ps -p ${XCODEBUILD_PIDS%% *} -o command=   # 対象端末を確認し、無関係でなければ終わるまで待つ"
fi

# ---- 3) ソフトキーボードが出る設定か ------------------------------------------------
# 1 = ハードウェアキーボード接続 = **画面上のソフトキーボードが一切出ない**。
# これを見落として「タップが効かない」→「座標系が違う」と誤診した実例がある(FEEDBACK §0)。
CHK="$(defaults read com.apple.iphonesimulator ConnectHardwareKeyboard 2>/dev/null | tr -d '[:space:]')"
case "$CHK" in
  1) HW_KB=true ;;
  0) HW_KB=false ;;
  *) HW_KB=null ;;   # キーが未設定。既定値は環境依存なので「不明」として扱う
esac
if [[ "$HW_KB" == true ]]; then
  add_warn "hardware_keyboard_connected" "warn" \
    "ConnectHardwareKeyboard=1。ソフトキーボードが表示されないため、入力・キーボード関連の観測は全部無効になる。" \
    "defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false   # 反映に Simulator.app 再起動が要ることがある(GUI なら ⌘K)"
fi

# ---- 4) システムプロキシ(新品端末の TLS を全部落とす) ------------------------------
# Simulator は macOS のシステムプロキシ設定を継承する。scutil --proxy が「実際に効いている」
# 設定なので主判定に使い、networksetup は Wi-Fi サービス個別の裏取りに使う
# (SKILL.md の手順が networksetup なので、そちらの結果も残しておくと突き合わせやすい)。
PROXY_HOST=""; PROXY_PORT=""
SCUTIL_OUT="$(scutil --proxy 2>/dev/null)"
if printf '%s' "$SCUTIL_OUT" | grep -qE 'HTTPSEnable[[:space:]]*:[[:space:]]*1'; then
  PROXY_HOST="$(printf '%s\n' "$SCUTIL_OUT" | awk '/HTTPSProxy[[:space:]]*:/{print $3; exit}')"
  PROXY_PORT="$(printf '%s\n' "$SCUTIL_OUT" | awk '/HTTPSPort[[:space:]]*:/{print $3; exit}')"
fi
NETSETUP_WIFI="$(networksetup -getsecurewebproxy "Wi-Fi" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g;s/ *$//')"
if [[ -z "$PROXY_HOST" ]] && printf '%s' "$NETSETUP_WIFI" | grep -qi 'Enabled: Yes'; then
  PROXY_HOST="$(printf '%s' "$NETSETUP_WIFI" | awk '/Server:/{print $4}')"
  PROXY_PORT="$(printf '%s' "$NETSETUP_WIFI" | awk '/Port:/{print $6}')"
fi
CAPTURE_PROCS="$(pgrep -lf 'Proxyman|Charles|mitmproxy' 2>/dev/null | awk '{print $2}' | xargs -n1 basename 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ *$//')"
CAPTURE_JSON=()
for p in $CAPTURE_PROCS; do CAPTURE_JSON+=("$(json_str "$p")"); done

if [[ -n "$PROXY_HOST" ]]; then
  add_warn "system_proxy_active" "warn" \
    "システム HTTPS プロキシが有効(${PROXY_HOST}:${PROXY_PORT:-?})。Simulator はこれを継承するので、CA を信頼していない新品端末では HTTPS が全部落ちる(『サーバの識別情報を検証できません』/ error -999)。" \
    "scripts/sim-trust-ca.sh --udid $UDID   # 端末にだけ CA を入れる(グローバル設定は触らない)"
elif [[ -n "$CAPTURE_PROCS" ]]; then
  # プロキシ設定は入っていないがキャプチャツールは起動中 —— 途中で有効化されると
  # 「さっきまで動いていた通信が急に落ちる」形で交絡する。存在だけ知らせておく。
  add_warn "capture_tool_running" "warn" \
    "キャプチャツールが起動中($CAPTURE_PROCS)。今はシステムプロキシ未設定だが、有効化された瞬間から新品端末の TLS が落ちる。" \
    "scripts/sim-trust-ca.sh --udid $UDID --dry-run   # 先に CA の在処だけ確認しておく"
fi

# ---- 5) idb と companion 接続 --------------------------------------------------------
IDB_CLI=false; IDB_CONN=null
if command -v idb >/dev/null 2>&1; then
  IDB_CLI=true
  TARGETS="$(run_timeout 20 idb list-targets 2>/dev/null)"
  RC=$?
  if (( RC == 124 )); then
    add_warn "idb_unresponsive" "warn" \
      "idb list-targets が 20s 応答しない(companion が死んでいる可能性)。" \
      "idb kill && idb connect $UDID"
  else
    LINE="$(printf '%s\n' "$TARGETS" | grep -iF "$UDID" | head -1)"
    if [[ -z "$LINE" ]]; then
      IDB_CONN=false
      add_warn "idb_target_missing" "warn" \
        "idb list-targets に $UDID の行が無い。" \
        "idb connect $UDID"
    elif printf '%s' "$LINE" | grep -qi 'No Companion Connected'; then
      IDB_CONN=false
      add_warn "idb_companion_not_connected" "warn" \
        "companion が $UDID にアタッチされていない(No Companion Connected)。idb ui * が無反応になる。" \
        "idb connect $UDID"
    else
      IDB_CONN=true
    fi
  fi
else
  add_warn "idb_missing" "warn" \
    "idb(fb-idb CLI)が無い。screenshot/launch/open_url は simctl だけで動くが、tap/swipe/text とアクセシビリティ走査はできない。" \
    "uv tool install fb-idb && idb connect $UDID"
fi

# ---- 6) 座標スケール(pixel 実寸 ÷ point 実寸) --------------------------------------
# ここが取れていれば「スクショの px をそのまま tap に渡す」事故を数値で自覚できる。
# ただし本命の対策はスケールを人に計算させないこと(sim-tap.py / sim-nav.py)。
PXW=null; PXH=null; PTW=null; PTH=null; SCALE=null
if (( WANT_SCALE )) && [[ "$TARGET_BOOTED" == true ]]; then
  PROBE="$HOME/tmp-sim/.sim-preflight-probe.png"
  mkdir -p "$(dirname "$PROBE")" 2>/dev/null
  # pixel 実寸は「実際に保存された画像」を測るのが確実(enumerate の公称値は撮影設定と食い違いうる)。
  if run_timeout 30 xcrun simctl io "$UDID" screenshot "$PROBE" >/dev/null 2>&1; then
    PXW="$(sips -g pixelWidth  "$PROBE" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    PXH="$(sips -g pixelHeight "$PROBE" 2>/dev/null | awk '/pixelHeight/{print $2}')"
    : "${PXW:=null}" "${PXH:=null}"
  fi
  # probe は「測るためだけ」の使い捨て。失敗時に半端なファイルを残さないよう必ず消す
  # (~/tmp-sim/ は成果物置き場なので、ゴミを混ぜると後で「これは何のスクショ?」になる)。
  rm -f "$PROBE"
  if [[ "$IDB_CLI" == true ]]; then
    RECT="$(run_timeout 30 idb ui describe-all --udid "$UDID" --json 2>/dev/null | max_frame_from_stdin)"
    read -r PTW PTH <<< "${RECT:-}"
    : "${PTW:=null}" "${PTH:=null}"
  fi
  if [[ "$PXW" != null && "$PTW" != null ]]; then
    SCALE="$(awk -v p="$PXW" -v q="$PTW" 'BEGIN{printf "%.3g", p/q}')"
  elif [[ "$IDB_CLI" == true && "$IDB_CONN" != false ]]; then
    # describe-all が空 or frame 全部 0 = ほぼ「対象アプリが前面にいない」印(FEEDBACK §2)。
    # AX/HID の故障と誤診して端末を再起動した実例があるので、切り分けの一手を fix に入れる。
    add_warn "scale_unknown" "warn" \
      "point 実寸を取得できなかった(describe-all が空 or frame 全部 0)。対象アプリが前面にいない可能性が高い。" \
      "xcrun simctl launch --terminate-running-process $UDID <bundle-id>   # 数秒待って再実行"
  fi
fi

# ---- 出力 --------------------------------------------------------------------------
OK=true
(( ${#WARNINGS[@]} > 0 )) && OK=false

fmt_pair() { # 数値2つを JSON 配列にする(片方でも null なら null)
  if [[ "$1" == null || "$2" == null || -z "$1" || -z "$2" ]]; then printf 'null'; else printf '[%s,%s]' "$1" "$2"; fi
}

printf '{"udid":%s,"name":%s,"booted":%s,"ok":%s,"booted_devices":[%s],' \
  "$(json_str "$UDID")" "$(json_str "$TARGET_NAME")" "$TARGET_BOOTED" "$OK" "$(join_json "${BOOTED_JSON[@]+"${BOOTED_JSON[@]}"}")"
printf '"idb":{"cli":%s,"companion_connected":%s},' "$IDB_CLI" "$IDB_CONN"
printf '"keyboard":{"connect_hardware_keyboard":%s},' "$HW_KB"
printf '"proxy":{"system_https_proxy":%s,"networksetup_wifi":%s,"capture_processes":[%s]},' \
  "$( [[ -n "$PROXY_HOST" ]] && json_str "${PROXY_HOST}:${PROXY_PORT:-?}" || printf 'null' )" \
  "$( [[ -n "$NETSETUP_WIFI" ]] && json_str "$NETSETUP_WIFI" || printf 'null' )" \
  "$(join_json "${CAPTURE_JSON[@]+"${CAPTURE_JSON[@]}"}")"
printf '"processes":{"xcodebuild":%s},' "$XCODEBUILD_COUNT"
printf '"pixel_size":%s,"point_size":%s,"scale":%s,' \
  "$(fmt_pair "$PXW" "$PXH")" "$(fmt_pair "$PTW" "$PTH")" "${SCALE:-null}"
printf '"warnings":[%s]}\n' "$(join_json "${WARNINGS[@]+"${WARNINGS[@]}"}")"

if [[ "$TARGET_BOOTED" != true ]]; then
  err "→ 対象端末が Booted でない。ここから先の観測は全部無意味なので、先に boot すること。"
  exit 3
fi
if [[ "$OK" != true ]]; then
  err "→ 警告 ${#WARNINGS[@]} 件。warnings[].fix をそのまま実行してから再実行する。"
  exit 1
fi
err "preflight ok: $TARGET_NAME ($UDID)"
exit 0
