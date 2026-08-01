#!/usr/bin/env bash
# sim-rec.sh — iOS Simulator ウィンドウだけを macOS 側の画面キャプチャ(ffmpeg avfoundation)で
# 録画する。xcrun simctl io recordVideo の代替。
#
# ★これは既定の録画手段ではない。既定は `xcrun simctl io <UDID> recordVideo`
#   (references/recording.md §2 の停止作法つき)。本スクリプトは
#   **「実時間と一致する尺が要る」かつ「録画中にタップしない」**ときにだけ使う。
#   理由は下の「実測」を読むこと。
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
# Usage:
#   sim-rec.sh start [out.mp4]   # 録画開始(バックグラウンド起動。PID を状態ファイルに保存)
#   sim-rec.sh stop              # SIGINT を送り、プロセスの exit を実際に待ってから戻る
#
# 前提: Simulator.app のウィンドウが最前面にあること(隠れていると真っ黒 or 他ウィンドウが写る)。
#       macOS の「画面収録」権限がターミナル/実行プロセスに付与済みであること。
set -uo pipefail

# 既定を $HOME 配下にする理由: (1) このスキルの他スクリプト(sim-shot.sh)が ~/tmp-sim/ を
# 既定にしており、成果物の置き場を散らかさない (2) /tmp は再起動で消えるが、録画は
# 撮り直しコストが高い成果物なので消えると困る。/tmp に置きたいなら SIM_REC_STATE_DIR で上書きする。
STATE_DIR="${SIM_REC_STATE_DIR:-$HOME/tmp-sim/sim-rec}"
mkdir -p "$STATE_DIR"
PIDFILE="$STATE_DIR/ffmpeg.pid"
OUTFILE_RECORD="$STATE_DIR/current_output.txt"

# avfoundation の画面デバイスは番号がマシン依存(list_devices で "Capture screen 0" を検索)。
find_screen_device_index() {
  ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
    | grep -i "Capture screen 0" \
    | sed -E 's/^.*\[([0-9]+)\].*$/\1/' \
    | head -1
}

# Simulator ウィンドウの矩形(points)を取得し、Retina スケールを掛けて pixel 矩形にする。
# スケールは Finder デスクトップの point 幅 と avfoundation 実キャプチャ幅の比から動的に出す
# (system_profiler の見かけ表示に頼らない。scaled resolution 環境で見かけと実描画が食い違うため)。
get_window_rect_px() {
  local win_bounds pt_x1 pt_y1 pt_x2 pt_y2 pt_w pt_h
  win_bounds=$(osascript -e 'tell application "Simulator" to activate' \
                          -e 'delay 0.3' \
                          -e 'tell application "System Events" to tell process "Simulator" to get {position, size} of window 1' 2>/dev/null \
               | grep -Eo '^-?[0-9]+, [0-9]+, [0-9]+, [0-9]+$' | tail -1)
  # 出力例: "268, 165, 456, 972" (x, y, w, h の順で position と size が連結される)
  IFS=',' read -r px py pw ph <<< "$(echo "$win_bounds" | tr -d ' ')"
  if [[ -z "${px:-}" || -z "${ph:-}" ]]; then
    echo "ERROR: Simulator ウィンドウの矩形取得に失敗(起動して前面にあるか確認)" >&2
    return 1
  fi

  local desktop_bounds desktop_w
  desktop_bounds=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null)
  desktop_w=$(echo "$desktop_bounds" | cut -d',' -f3 | tr -d ' ')

  # NOTE: ffmpeg 呼び出しの stderr/stdout をそのまま変数に混ぜると、objc ランタイムの
  # 重複クラス登録警告(loglevel 制御が効かない dyld/objc 由来の出力)が数値と一緒に
  # 変数へ入り込み、後続の awk が "newline in string" で壊れる(実際にハマった)。
  # ffmpeg 側の出力は必ず別ログファイルに逃がし、cap_w には sips|awk の純粋な数値だけを入れる。
  ffmpeg -y -f avfoundation -framerate 5 -i "$(find_screen_device_index)" -frames:v 1 "$STATE_DIR/_probe.png" -loglevel error > "$STATE_DIR/_probe.ffmpeg.log" 2>&1
  local cap_w
  cap_w=$(sips -g pixelWidth "$STATE_DIR/_probe.png" 2>/dev/null | awk '/pixelWidth/{print $2}')

  local scale
  scale=$(awk -v c="$cap_w" -v d="$desktop_w" 'BEGIN{printf "%.6f", c/d}')

  local X Y W H
  X=$(awk -v p="$px" -v s="$scale" 'BEGIN{printf "%d", p*s}')
  Y=$(awk -v p="$py" -v s="$scale" 'BEGIN{printf "%d", p*s}')
  W=$(awk -v p="$pw" -v s="$scale" 'BEGIN{printf "%d", p*s}')
  H=$(awk -v p="$ph" -v s="$scale" 'BEGIN{printf "%d", p*s}')
  echo "$X $Y $W $H"
}

cmd_start() {
  local out="${1:-$STATE_DIR/rec_$(date +%Y%m%d_%H%M%S).mp4}"
  if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "ERROR: 既に録画中(PID $(cat "$PIDFILE"))。先に stop してください。" >&2
    exit 1
  fi

  read -r X Y W H <<< "$(get_window_rect_px)" || exit 1
  echo "window rect (px): x=$X y=$Y w=$W h=$H"

  local dev_idx
  dev_idx=$(find_screen_device_index)
  local errlog="$STATE_DIR/ffmpeg.stderr.log"

  ffmpeg -y -f avfoundation -capture_cursor 0 -framerate 30 -i "$dev_idx" \
    -vf "crop=${W}:${H}:${X}:${Y}" -c:v h264 -pix_fmt yuv420p \
    "$out" > "$STATE_DIR/ffmpeg.stdout.log" 2> "$errlog" &
  local pid=$!
  echo "$pid" > "$PIDFILE"
  echo "$out" > "$OUTFILE_RECORD"

  # ffmpeg が実際に書き込みを始めるまで少し待つ(frame=... が出るまで、最大5秒)
  for _ in $(seq 1 50); do
    grep -q "frame=" "$errlog" 2>/dev/null && break
    sleep 0.1
  done
  echo "recording started: pid=$pid out=$out"
}

cmd_stop() {
  if [[ ! -f "$PIDFILE" ]]; then
    echo "ERROR: 録画中のプロセスが見つからない($PIDFILE なし)" >&2
    exit 1
  fi
  local pid out
  pid=$(cat "$PIDFILE")
  out=$(cat "$OUTFILE_RECORD" 2>/dev/null || echo "?")

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "WARN: PID $pid は既に終了している" >&2
  else
    # ffmpeg は SIGINT で "q" と同様にクリーンシャットダウンする(moov atom 書き込み含む)。
    # 注意: start は別の Bash 呼び出し(=別シェルプロセス)で起動しているため、この $pid は
    # 「このシェルの子」ではない。bash 組み込みの wait は他人の子を待てず即座に失敗して
    # 返ってくるので、実際には exit を待たずに次へ進んでしまう(実際にこれで moov atom
    # not found = 壊れた mp4 を作った)。kill -0 でプロセス存在をポーリングする方式に倒す。
    kill -INT "$pid"
    for _ in $(seq 1 100); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "WARN: 1秒待っても $pid が終了しない。SIGTERM を送る" >&2
      kill -TERM "$pid" 2>/dev/null
      for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
    fi
  fi
  rm -f "$PIDFILE" "$OUTFILE_RECORD"
  echo "stopped. output: $out"
  if command -v ffprobe >/dev/null 2>&1 && [[ -f "$out" ]]; then
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 "$out"
  fi
}

case "${1:-}" in
  start) cmd_start "${2:-}" ;;
  stop) cmd_stop ;;
  *) echo "usage: $0 <start [out.mp4]|stop>" >&2; exit 1 ;;
esac
