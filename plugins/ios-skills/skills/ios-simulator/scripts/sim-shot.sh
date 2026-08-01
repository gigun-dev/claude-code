#!/usr/bin/env bash
# 起動済み iOS Simulator のスクリーンショットを撮り、座標空間を「毎回明示」する。
#
# Why: スクショは pixels、idb ui tap は points。この2空間の食い違いが「撮った画像の座標で
# タップしたのにズレる」問題の根源。Anthropic の Desktop ツールはスクショと一緒に
# "Coordinate space for screenshot/tap/swipe: {W}x{H} pixels (origin top-left)." を毎回返して
# 食い違いを消している。ここではそれを再現し、さらに point 実寸と scale も出して
# 「pixel 座標 ÷ scale = point 座標(= idb ui tap に渡す値)」を機械的に導けるようにする。
#
# Why UDID 必須(2026-08-01 変更・後方互換を意図的に壊した):
#   旧版は `xcrun simctl io booted screenshot` 決め打ちで UDID を受け取れなかった。
#   実地(booted 4台の日)でこれを呼んだところ **別エージェントが作業中の端末を撮ってしまった**。
#   読み取り専用だったので実害は無かったが、「触らない約束の端末に触った」という事故そのもの。
#   simctl の `booted` は「Booted な端末が1台だけならそれ、複数なら不定」という危険な糖衣なので、
#   このスキルの4本(sim-shot/sim-tap/sim-wait/sim-act)は全て --udid か SIM_UDID を必須にして、
#   「省略したら暗黙に何かへ飛ぶ」経路を構造的に塞ぐ。
#   ボツ案: 未指定時に「Booted が1台だけなら自動でそれを使う」フォールバック
#     → 「今日はたまたま1台だった」ときに動いてしまい、2台になった日に静かに誤爆する。
#       静かな誤爆こそがこのスキルで最も高くついた失敗なので、便利さより明示を採る。
#
# Why 出力先の既定が $HOME 配下:
#   エージェント実行環境の sandbox は /tmp 配下への書き込みを弾く
#   (NSCocoaErrorDomain code=642 "the volume ... is read only")。simctl 側の権限問題ではないので
#   sudo でも Simulator 再起動でも直らない。セッション用 scratchpad が /tmp 配下にある場合も同じ。
#   よって既定を ~/tmp-sim にし、/tmp 配下を指定されたら撮る前に警告する。
#
# Usage:
#   sim-shot.sh --udid <UDID> [出力パス]
#   SIM_UDID=<UDID> sim-shot.sh [出力パス]        # 環境変数でも可(4本共通の流儀)
#   既定の出力パス: ~/tmp-sim/sim-shot-<UNIX時刻>.png
set -euo pipefail

UDID="${SIM_UDID:-}"
OUT=""

# 引数パース。位置引数(出力パス)は旧版と同じ場所に置けるよう維持する
# —— 壊したのは「UDID 省略可」だけで、出力パスの渡し方まで変えると既存メモが全部無効になるため。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid)
      UDID="${2:-}"
      shift 2 || true
      ;;
    --udid=*)
      UDID="${1#*=}"
      shift
      ;;
    -h|--help)
      sed -n '2,40p' "$0" >&2
      exit 0
      ;;
    *)
      OUT="$1"
      shift
      ;;
  esac
done

# エラー復帰の作法: 「失敗した」で止めず必ず次の一手を添える(4本で同じ文面に揃えてある)。
if [[ -z "$UDID" ]]; then
  {
    echo "UDID 未指定。--udid <UDID> か環境変数 SIM_UDID を指定すること。"
    echo "  → xcrun simctl list devices booted で対象を確認してから明示する"
    echo "    (複数 booted は現実に起きる。実地で4台同時 booted の日があり、'booted' 指定は"
    echo "     不定に化けて他人の端末を撮る事故になったため、意図的に必須化している)。"
  } >&2
  # exit 1 に揃える(usage エラーの慣習では 2 だが、4本の呼び出し規約を統一する方を優先。
  # python 側は sys.exit("メッセージ") で必ず 1 になるため)。
  exit 1
fi

OUT="${OUT:-$HOME/tmp-sim/sim-shot-$(date +%s).png}"

# /tmp 配下は sandbox に弾かれる。撮ってから 642 で落ちると原因が分かりにくいので先に言う。
case "$OUT" in
  /tmp/*|/private/tmp/*)
    echo "警告: 出力先 '$OUT' は /tmp 配下。sandbox 下では書き込みが弾かれる(code=642)ことがある。" >&2
    echo "  → 弾かれたら ~/tmp-sim/ に撮ってから mv すること。" >&2
    ;;
esac

mkdir -p "$(dirname "$OUT")"

# simctl 単体で撮れる(idb 不要)。
# 旧版は stderr を /tmp/sim-shot.err に落としていたが、それ自体が上記の /tmp 書込み制約に
# 引っかかる自己矛盾だったので、変数に受けるように変えた。
if ! ERR="$(xcrun simctl io "$UDID" screenshot "$OUT" 2>&1)"; then
  {
    echo "screenshot に失敗(UDID=$UDID)。"
    echo "  → xcrun simctl list devices booted で当該 UDID が Booted か確認。"
    echo "    無ければ xcrun simctl boot \"$UDID\" してからリトライ。"
    echo "  → 'volume is read only' なら出力先が /tmp 配下。~/tmp-sim/ に撮り直す。"
    echo "$ERR"
  } >&2
  exit 1
fi

# pixel 実寸は sips(macOS 標準・依存ゼロ)で読む。
# 別解: `xcrun simctl io <UDID> enumerate` の "Default width/height" でも取れる(実測)。
# sips を採ったのは「実際に保存された画像そのもの」を測るため —— enumerate はデバイスの
# 公称値なので、将来スケール指定つきの撮影が入ったときに実ファイルと食い違いうる。
PXW=$(sips -g pixelWidth  "$OUT" | awk '/pixelWidth/{print $2}')
PXH=$(sips -g pixelHeight "$OUT" | awk '/pixelHeight/{print $2}')

# point 実寸と scale は idb のアクセシビリティ・ルート frame(points)から導く。
# idb が無ければ scale 不明として pixel だけ返す(screenshot 自体は成立しているので致命ではない)。
PTW="" ; SCALE=""
if command -v idb >/dev/null 2>&1; then
  # describe-all の最も広い frame = 画面全体(ルート)とみなし、その width を point 幅とする。
  # jq に依存しないよう Python(uv 経由・stdlib のみ)で 1 個だけ取り出す。
  # 注: describe-all は **入れ子の JSON 配列**を返すことがある(トップレベルが flat な配列とは限らない)。
  #     ここは幅の最大値さえ取れれば良いので、再帰で全 dict を舐める実装にしてある。
  PTW=$(idb ui describe-all --udid "$UDID" --json 2>/dev/null | uv run --quiet - <<'PY' 2>/dev/null || true
import sys, json
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
# describe-all は JSON(配列 or 入れ子) or JSON-lines のどちらもあり得るので両対応。
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    data = [json.loads(l) for l in raw.splitlines() if l.strip()]

widths = []
def walk(n):
    if isinstance(n, list):
        for i in n:
            walk(i)
    elif isinstance(n, dict):
        w = (n.get("frame") or {}).get("width") if isinstance(n.get("frame"), dict) else None
        if isinstance(w, (int, float)) and w > 0:
            widths.append(w)
        for v in n.values():
            walk(v)
walk(data)
if widths:
    print(int(round(max(widths))))
PY
)
  if [[ -n "$PTW" && "$PTW" -gt 0 ]]; then
    # scale = pixel幅 / point幅(整数近似。Retina は 2 or 3)。
    SCALE=$(awk -v p="$PXW" -v q="$PTW" 'BEGIN{printf "%.3g", p/q}')
  fi
fi

echo "saved: $OUT  (udid=$UDID)"
echo "Coordinate space for screenshot: ${PXW}x${PXH} pixels (origin top-left)."
if [[ -n "$PTW" && -n "$SCALE" ]]; then
  PTH=$(awk -v h="$PXH" -v s="$SCALE" 'BEGIN{printf "%d", h/s}')
  echo "Coordinate space for idb ui tap/swipe: ${PTW}x${PTH} points (origin top-left)."
  echo "scale = ${SCALE}  →  point座標 = pixel座標 ÷ ${SCALE}  (ラベル指定なら sim-tap.py が変換不要)"
elif command -v idb >/dev/null 2>&1; then
  # ここが「idb はあるのに point 幅が取れなかった」= widths が空だったケース。
  # 実地ではこれの正体はほぼ **describe-all が frame:{0,0,0,0} の1要素しか返していない**、
  # つまり「対象アプリが前面にいない」印(FEEDBACK 2026-08-01 §2 の実測)。
  # 旧版はここも一律「idb 未接続」と案内していたが、それは誤誘導 —— この一言が無かったせいで
  # 「AX/HID が壊れた」と誤診して shutdown→boot まで走った例がある。切り分けの一手を明示する。
  {
    echo "注意: idb はあるが point 幅を取得できなかった(describe-all が空 or frame 全部 0)。"
    echo "  → これは AX/HID の故障とは限らない。まず『対象アプリが前面にいない』を疑う:"
    echo "    xcrun simctl launch --terminate-running-process $UDID <bundle-id> して数秒待ってからリトライ。"
    echo "  → それでも駄目なら companion 接続を確認: idb list-targets / idb connect $UDID"
  } >&2
else
  echo "(idb 未導入のため point/scale 不明。uv tool install fb-idb → idb connect $UDID 後に再実行するか、sim-tap.py でラベル指定タップを推奨)"
fi
