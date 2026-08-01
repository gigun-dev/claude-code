#!/usr/bin/env bash
# sim-rec.sh — iOS Simulator ウィンドウだけを macOS 側の画面キャプチャ(ffmpeg avfoundation)で
# 録画する。xcrun simctl io recordVideo の代替。
#
# ★これは既定の録画手段ではない。既定は `xcrun simctl io <UDID> recordVideo`
#   (references/recording.md §2 の停止作法つき)。本スクリプトは
#   **「実時間と一致する尺が要る」かつ「録画中にタップしない」**ときにだけ使う。
#
# Why (背景・2026-08-01 の対照実験の結果):
# - simctl io recordVideo はコンテナの尺が実時間と一致しない(実測: 24.32s の動画が
#   実際にはもっと長い実操作を記録していた)。SIGINT を実PIDに送って exit を待つ
#   「正しい作法」を守っても直らない。加えて画面が変化しない間はフレームがほぼ
#   出ない(実測: 15秒間無操作で nb_frames=1)ため、イベント駆動の可変フレームレート
#   記録という設計そのものが「実時間の動画」という用途に向いていない。
#   → ここが本スクリプトの存在理由。実測で 15.01s の実時間が 15.57s として記録され、
#      フレームレートも 30/1 で一貫した。
#
# - ★ボツになった当初の目的(記録として残す): 「ffmpeg は SimDevice の IO ポートに
#   触らないから、録画中のタップ競合を避けられるはず」という仮説で作り始めた。
#   **対照実験でこの仮説は否定された。**
#     録画なし          : 20 タップ中 0 失敗
#     simctl recordVideo: 20 タップ中 0 失敗  ← 壊すと思われていた方が無傷だった
#     ffmpeg avfoundation: 20 タップ中 10 失敗 ← 「安全な代替」のはずがこちらが落とした
#   失敗は idb の自己申告ではなく `xcrun simctl io screenshot` の前後バイト比較で裏取り済み。
#   推定原因(未確証): フル画面 3600x2338 を 30fps で H.264 エンコードして CPU 32〜34%、
#   `libx264: MB rate > level limit` の警告が出るほど重く、Simulator 側の描画/イベント処理を
#   遅延させた。つまり「共有 IO ポートの奪い合い」ではなく単なる CPU 競合の可能性が高い。
#
# - したがって実務ルールは **「撮るときは触らない、触るときは撮らない」**(ツールに依らず)。
#   録画中に idb で操作する必要があるなら、本スクリプトではなく simctl 録画を使うこと。
#
# Why --udid が「あった方がよいが必須ではない」唯一のスクリプト:
#   ffmpeg が撮るのは**画面上のウィンドウ**であって端末ではない。--udid を渡すと
#   その端末名のウィンドウを探して前面に出してから撮る(複数 Simulator ウィンドウが開いている
#   ときの撮り違いを防ぐ)。渡さない場合は「Simulator の window 1」を撮る = 誰の端末かは運任せ。
#   実走行で「意図しない端末を掴む」事故が起きているので、**渡すことを強く推奨**する。
set -uo pipefail   # set -e は使わない(probe の失敗を値として扱いたい)

usage() {
  cat <<'EOF'
Usage: sim-rec.sh start [--udid <UDID>] [OUT.mp4]
       sim-rec.sh stop
       sim-rec.sh status

Simulator ウィンドウを ffmpeg(avfoundation)で録画する。結果は JSON で stdout、経過は stderr。

★既定の録画手段ではない。既定は `xcrun simctl io <UDID> recordVideo`
  (references/recording.md §2)。本スクリプトを使うのは
  **「実時間と一致する尺が要る」かつ「録画中にタップしない」**ときだけ。
  実測で、ffmpeg 録画中のタップは 20 回中 10 回落ちた(CPU 競合が原因と推定)。
  → 撮るときは触らない、触るときは撮らない。

Options:
  --udid <UDID>   撮りたい端末(環境変数 SIM_UDID でも可)。その端末名のウィンドウを前面に出して撮る。
                  省略すると Simulator の「window 1」= どの端末かは運任せ(推奨しない)。
  OUT.mp4         出力パス(既定: ~/tmp-sim/sim-rec/rec_<日時>.mp4)
  -h, --help      このヘルプ

前提: macOS の「画面収録」権限が実行プロセスに付与済みであること。ffmpeg / ffprobe があること。

Output (stdout, JSON):
  start : {"status":"started","pid":1234,"output":"...","rect":[x,y,w,h],"udid":"..."}
          既に録画中なら {"status":"already_recording","pid":1234,"output":"..."}(冪等・exit 0)
  stop  : {"status":"stopped","output":"...","duration":15.57}
          録画していなければ {"status":"not_recording"}(冪等・exit 0)
  status: {"status":"recording"|"idle","pid":1234,"output":"..."}

Exit codes (このスキルの全スクリプト共通):
  0  成功(冪等な no-op を含む)
  2  引数不正(未知のサブコマンド等)
  3  端末/ウィンドウが見つからない
  7  前提不足(ffmpeg 不在、画面収録権限なし等)
  ※ 4/5/6 はこのスクリプトでは使わない。

Examples:
  scripts/sim-rec.sh start --udid EF5D841C-... ~/tmp-sim/run1.mp4
  scripts/sim-rec.sh status
  scripts/sim-rec.sh stop
EOF
}

err() { printf '%s\n' "$@" >&2; }
json_str() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }
list_booted() {
  xcrun simctl list devices booted 2>/dev/null \
    | sed -n 's/^[[:space:]]*\(.*\) (\([0-9A-Fa-f-]\{20,\}\)) (Booted).*/\2	\1/p'
}
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# 既定を $HOME 配下にする理由: (1) このスキルの他スクリプト(sim-shot.sh)が ~/tmp-sim/ を
# 既定にしており、成果物の置き場を散らかさない (2) /tmp は再起動で消えるうえ、sandbox 下では
# 書き込み自体が弾かれる(code=642)。/tmp に置きたいなら SIM_REC_STATE_DIR で上書きする。
STATE_DIR="${SIM_REC_STATE_DIR:-$HOME/tmp-sim/sim-rec}"
mkdir -p "$STATE_DIR" 2>/dev/null
PIDFILE="$STATE_DIR/ffmpeg.pid"
OUTFILE_RECORD="$STATE_DIR/current_output.txt"

UDID="${SIM_UDID:-}"

# avfoundation の画面デバイスは番号がマシン依存(list_devices で "Capture screen 0" を検索)。
find_screen_device_index() {
  ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
    | grep -i "Capture screen 0" \
    | sed -E 's/^.*\[([0-9]+)\].*$/\1/' \
    | head -1
}

# UDID から端末名を引く(ウィンドウ選択に使う)。見つからなければ空。
device_name_for() {
  local want; want="$(upper "$1")"
  list_booted | while IFS=$'\t' read -r u n; do
    [[ "$(upper "${u:-}")" == "$want" ]] && printf '%s' "$n"
  done
}

# Simulator ウィンドウの矩形(points)を取得し、Retina スケールを掛けて pixel 矩形にする。
# スケールは Finder デスクトップの point 幅 と avfoundation 実キャプチャ幅の比から動的に出す
# (system_profiler の見かけ表示に頼らない。scaled resolution 環境で見かけと実描画が食い違うため)。
get_window_rect_px() {
  local name="${1:-}" win_bounds
  if [[ -n "$name" ]]; then
    # 端末名でウィンドウを選び、AXRaise で前面に出してから測る。
    # Why: ffmpeg は「画面の矩形」を撮るだけなので、別のウィンドウが上に被っていると
    #      そちらが写る。撮り違いは後から気づけない(動画を見るまで分からない)ので先に潰す。
    win_bounds=$(osascript \
      -e 'on run argv' \
      -e 'tell application "Simulator" to activate' \
      -e 'delay 0.3' \
      -e 'tell application "System Events" to tell process "Simulator"' \
      -e 'set ws to (every window whose name contains (item 1 of argv))' \
      -e 'if (count of ws) is 0 then error "no window"' \
      -e 'set w to item 1 of ws' \
      -e 'perform action "AXRaise" of w' \
      -e 'delay 0.3' \
      -e 'get {position, size} of w' \
      -e 'end tell' \
      -e 'end run' "$name" 2>/dev/null \
      | grep -Eo '^-?[0-9]+, -?[0-9]+, [0-9]+, [0-9]+$' | tail -1)
  fi
  if [[ -z "${win_bounds:-}" ]]; then
    [[ -n "$name" ]] && err "警告: 端末名 '$name' のウィンドウを特定できなかった。window 1 で代用する(撮り違いに注意)。"
    win_bounds=$(osascript -e 'tell application "Simulator" to activate' \
                            -e 'delay 0.3' \
                            -e 'tell application "System Events" to tell process "Simulator" to get {position, size} of window 1' 2>/dev/null \
                 | grep -Eo '^-?[0-9]+, -?[0-9]+, [0-9]+, [0-9]+$' | tail -1)
  fi
  # 出力例: "268, 165, 456, 972" (x, y, w, h の順で position と size が連結される)
  IFS=',' read -r px py pw ph <<< "$(printf '%s' "$win_bounds" | tr -d ' ')"
  if [[ -z "${px:-}" || -z "${ph:-}" ]]; then
    err "Simulator ウィンドウの矩形取得に失敗。" \
        "  → Simulator.app が起動して画面に出ているか確認する(最小化・別 Space も不可)。" \
        "  → System Events の自動化許可(アクセシビリティ)が実行プロセスに要る。"
    return 1
  fi

  local desktop_bounds desktop_w
  desktop_bounds=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null)
  desktop_w=$(printf '%s' "$desktop_bounds" | cut -d',' -f3 | tr -d ' ')

  # NOTE: ffmpeg 呼び出しの stderr/stdout をそのまま変数に混ぜると、objc ランタイムの
  # 重複クラス登録警告(loglevel 制御が効かない dyld/objc 由来の出力)が数値と一緒に
  # 変数へ入り込み、後続の awk が "newline in string" で壊れる(実際にハマった)。
  # ffmpeg 側の出力は必ず別ログファイルに逃がし、cap_w には sips|awk の純粋な数値だけを入れる。
  ffmpeg -y -f avfoundation -framerate 5 -i "$(find_screen_device_index)" -frames:v 1 "$STATE_DIR/_probe.png" -loglevel error > "$STATE_DIR/_probe.ffmpeg.log" 2>&1
  local cap_w
  cap_w=$(sips -g pixelWidth "$STATE_DIR/_probe.png" 2>/dev/null | awk '/pixelWidth/{print $2}')
  if [[ -z "${cap_w:-}" ]]; then
    err "画面キャプチャの probe に失敗($STATE_DIR/_probe.ffmpeg.log を見る)。" \
        "  → macOS の「画面収録」権限が実行プロセスに付いているか確認する。"
    return 1
  fi

  local scale
  scale=$(awk -v c="$cap_w" -v d="$desktop_w" 'BEGIN{printf "%.6f", c/d}')

  local X Y W H
  X=$(awk -v p="$px" -v s="$scale" 'BEGIN{printf "%d", p*s}')
  Y=$(awk -v p="$py" -v s="$scale" 'BEGIN{printf "%d", p*s}')
  W=$(awk -v p="$pw" -v s="$scale" 'BEGIN{printf "%d", p*s}')
  H=$(awk -v p="$ph" -v s="$scale" 'BEGIN{printf "%d", p*s}')
  printf '%s %s %s %s' "$X" "$Y" "$W" "$H"
}

recording_pid() {  # 録画中なら PID を返す。していなければ空。
  [[ -f "$PIDFILE" ]] || return 0
  local p; p="$(cat "$PIDFILE" 2>/dev/null)"
  if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then printf '%s' "$p"; fi
}

cmd_start() {
  local out="${1:-}"
  command -v ffmpeg >/dev/null 2>&1 || {
    err "ffmpeg が無い。" "  → brew install ffmpeg(または nix)。" \
        "  → そもそも既定の録画は xcrun simctl io <UDID> recordVideo。ffmpeg 版が要るか再考する。"
    exit 7
  }

  # 冪等性: 既に録画中なら二重起動せず、現状を返して 0 で終わる(エージェントはリトライする)。
  # ボツ案: エラーにする(旧実装) → リトライのたびに落ちるので、状態を返す方が扱いやすい。
  local running; running="$(recording_pid)"
  if [[ -n "$running" ]]; then
    printf '{"status":"already_recording","pid":%s,"output":%s}\n' \
      "$running" "$(json_str "$(cat "$OUTFILE_RECORD" 2>/dev/null)")"
    err "既に録画中(PID $running)。止めるなら sim-rec.sh stop。"
    exit 0
  fi

  local name=""
  if [[ -n "$UDID" ]]; then
    name="$(device_name_for "$UDID")"
    if [[ -z "$name" ]]; then
      err "UDID '$UDID' は Booted な端末として見つからない。" \
          "  → 現在 Booted な端末:" "$(list_booted)" \
          "  → 起動するなら xcrun simctl boot \"$UDID\"。"
      exit 3
    fi
  else
    err "警告: --udid 未指定。Simulator の window 1 を撮る(どの端末かは運任せ)。" \
        "  → 撮り違いを避けるなら --udid <UDID> を渡す。"
  fi

  out="${out:-$STATE_DIR/rec_$(date +%Y%m%d_%H%M%S).mp4}"
  mkdir -p "$(dirname "$out")" 2>/dev/null

  local rect X Y W H
  rect="$(get_window_rect_px "$name")" || exit 3
  read -r X Y W H <<< "$rect"
  err "window rect (px): x=$X y=$Y w=$W h=$H  ${name:+(window: $name)}"

  local dev_idx errlog
  dev_idx=$(find_screen_device_index)
  errlog="$STATE_DIR/ffmpeg.stderr.log"

  ffmpeg -y -f avfoundation -capture_cursor 0 -framerate 30 -i "$dev_idx" \
    -vf "crop=${W}:${H}:${X}:${Y}" -c:v h264 -pix_fmt yuv420p \
    "$out" > "$STATE_DIR/ffmpeg.stdout.log" 2> "$errlog" &
  local pid=$!
  printf '%s' "$pid" > "$PIDFILE"
  printf '%s' "$out" > "$OUTFILE_RECORD"

  # ffmpeg が実際に書き込みを始めるまで少し待つ(frame=... が出るまで、最大5秒)
  local i
  for i in $(seq 1 50); do
    grep -q "frame=" "$errlog" 2>/dev/null && break
    sleep 0.1
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    err "ffmpeg が即座に終了した。ログ: $errlog" \
        "  → 画面収録権限 / crop 矩形($W x $H)を確認する。"
    rm -f "$PIDFILE" "$OUTFILE_RECORD"
    exit 7
  fi
  printf '{"status":"started","pid":%s,"output":%s,"rect":[%s,%s,%s,%s],"udid":%s}\n' \
    "$pid" "$(json_str "$out")" "$X" "$Y" "$W" "$H" \
    "$( [[ -n "$UDID" ]] && json_str "$UDID" || printf 'null' )"
  err "recording started: pid=$pid out=$out  ★録画中は端末に触らないこと(タップが落ちる)。"
}

cmd_stop() {
  local pid out
  pid="$(recording_pid)"
  out="$(cat "$OUTFILE_RECORD" 2>/dev/null)"
  if [[ -z "$pid" ]]; then
    # 冪等性: 止まっているものを止めるのは成功(エージェントは stop を二度撃つ)。
    rm -f "$PIDFILE" "$OUTFILE_RECORD"
    printf '{"status":"not_recording","output":%s}\n' "$( [[ -n "$out" ]] && json_str "$out" || printf 'null' )"
    err "録画中のプロセスは無い(no-op)。"
    exit 0
  fi

  # ffmpeg は SIGINT で "q" と同様にクリーンシャットダウンする(moov atom 書き込み含む)。
  # 注意: start は別の Bash 呼び出し(=別シェルプロセス)で起動しているため、この $pid は
  # 「このシェルの子」ではない。bash 組み込みの wait は他人の子を待てず即座に失敗して
  # 返ってくるので、実際には exit を待たずに次へ進んでしまう(実際にこれで moov atom
  # not found = 壊れた mp4 を作った)。kill -0 でプロセス存在をポーリングする方式に倒す。
  kill -INT "$pid"
  local i
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    err "警告: 10秒待っても $pid が終了しない。SIGTERM を送る(mp4 が壊れる可能性)。"
    kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -f "$PIDFILE" "$OUTFILE_RECORD"

  local dur=null
  if command -v ffprobe >/dev/null 2>&1 && [[ -f "$out" ]]; then
    dur="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$out" 2>/dev/null)"
    [[ -z "$dur" ]] && dur=null
  fi
  printf '{"status":"stopped","output":%s,"duration":%s}\n' \
    "$( [[ -n "$out" ]] && json_str "$out" || printf 'null' )" "$dur"
  err "stopped. output: ${out:-?}"
}

cmd_status() {
  local pid out
  pid="$(recording_pid)"
  out="$(cat "$OUTFILE_RECORD" 2>/dev/null)"
  if [[ -n "$pid" ]]; then
    printf '{"status":"recording","pid":%s,"output":%s}\n' "$pid" "$( [[ -n "$out" ]] && json_str "$out" || printf 'null' )"
  else
    printf '{"status":"idle","pid":null,"output":null}\n'
  fi
}

SUB="${1:-}"
[[ $# -gt 0 ]] && shift
OUT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="${2:-}"; shift 2 || true ;;
    --udid=*) UDID="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) err "不明なオプション: $1" "  → scripts/sim-rec.sh --help"; exit 2 ;;
    *) OUT_ARG="$1"; shift ;;
  esac
done

case "$SUB" in
  start) cmd_start "$OUT_ARG" ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  -h|--help) usage; exit 0 ;;
  # 引数なしは「使い方の誤り」。usage は stderr に出して 2 で落とす(データを stdout に混ぜない)。
  "") usage >&2; err "サブコマンドが必要: start / stop / status"; exit 2 ;;
  *) err "不明なサブコマンド: $SUB" "  → start / stop / status のいずれか。詳細は --help。"; exit 2 ;;
esac
