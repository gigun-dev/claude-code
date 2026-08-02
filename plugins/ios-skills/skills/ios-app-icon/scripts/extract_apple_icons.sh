#!/usr/bin/env bash
# インストール済み Simulator ランタイムから、Apple 純正アプリのアイコン素材を抽出する。
#
# なぜこれが効くか:
# 「モダンなアイコンを作って」と言われて手が止まるのは、参照する設計言語が無いから。
# 純正アイコンを実際に並べて見ると、思い込みが具体的に壊れる。実例:
#   - 背景は白/淡色が主流(カレンダー・リマインダー・ヘルス・ファイル)。
#     ブランド色のベタ塗り一択は古い。ベタ塗りはメッセージなど一部だけ。
#   - 前景は多色でよい(リマインダーの青赤橙、ウォレットの3色カード)。
#   - カレンダーは日付を数字でなくドット格子で抽象化する。意味を説明しない。
#   - ショートカットは半透明の角丸菱形が2枚重なるだけ。重なりの透過そのものがデザイン。
#     Liquid Glass は重なりを屈折させるので、この語彙が最も「iOS 26 らしく」出る。
#
# 取れるのは AppIcon60x60@2x.png(120px・Liquid Glass 適用前のフラット素材)。
# 小さいが、構図・配色・抽象度を読むには十分。
#
# 使い方:
#   extract_apple_icons.sh <出力ディレクトリ> [アプリ名...]
# アプリ名を省略すると**ランタイム内の全アプリ**から取る。
# 抽出後 grid.swift に通すと一覧で比較できる(数十枚を眺めるならこちら。
# contact_sheet.swift は数案を大きく見る用で、参照集めには粒度が合わない)。
#
# 【既定を「代表的な22個の決め打ちリスト」から全件へ変えた理由・2026-08-02】
# 決め打ちだと、リストにある名前でも実際のバンドル名や配置が違えば黙って落ちる。
# 実際に 22 個指定して 8 個しか取れず、それに気づかないまま「純正を見た」と称して
# 設計判断をしていた(ユーザーに「ちゃんと見た?」と指摘されて発覚)。参照を集める
# 工程で母数が 1/3 に痩せるのは、思い込みを壊すというこの手順の目的を無効化する。
# 全件取ってから目で捨てるほうが速いし、落ちたことにも気づける。

set -euo pipefail

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  cat <<'EOF'
Usage: extract_apple_icons.sh <out-dir> [AppName ...]

Extract app icons from the first installed iOS Simulator runtime. With no app names,
extract from all runtime applications.
EOF
  exit 0
fi
if [[ $# -lt 1 ]]; then
  echo "usage: $0 <out-dir> [AppName ...]" >&2
  exit 2
fi
OUT="$1"
shift || true

APPS=("$@")

# ランタイムは Xcode 同梱と、別ボリュームにマウントされる新形式の2系統がある。
# 新形式(/Library/Developer/CoreSimulator/Volumes/iOS_XXXXX/)は .simruntime までが
# 深く、maxdepth 6 では届かない —— 実際にこれで「ランタイムが見つからない」と誤判定した。
RUNTIME_DIR=$(find /Library/Developer/CoreSimulator/Volumes \
                   /Library/Developer/CoreSimulator/Profiles/Runtimes \
                   /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Library/Developer/CoreSimulator/Profiles/Runtimes \
                   -maxdepth 9 -name "*.simruntime" 2>/dev/null | head -1 || true)
# `|| true` が要る理由: head が1行読んで閉じると find に SIGPIPE が飛び、
# pipefail のせいでパイプライン全体が失敗扱いになり、set -e で**何も言わずに終了**する。
# ランタイムは見つかっているのに 0 件で終わる、という分かりにくい壊れ方をした。

if [ -z "$RUNTIME_DIR" ]; then
  echo "error: no iOS simruntime found. Install a Simulator runtime via Xcode." >&2
  exit 1
fi

APP_DIR="$RUNTIME_DIR/Contents/Resources/RuntimeRoot/Applications"
if [ ! -d "$APP_DIR" ]; then
  echo "error: Applications dir not found under $RUNTIME_DIR" >&2
  exit 1
fi

echo "runtime: $RUNTIME_DIR"
mkdir -p "$OUT"

# アプリ名を明示されたらそれだけ、省略されたら全アプリ。ファイル名はアプリ名にする
# (連番を前置しない —— どれが何か分からないと設計言語の読み取りに使えない)。
if [ ${#APPS[@]} -eq 0 ]; then
  FILES=$(find "$APP_DIR" -maxdepth 2 -name "AppIcon60x60@2x.png" 2>/dev/null | sort)
else
  FILES=""
  for app in "${APPS[@]}"; do
    f="$APP_DIR/$app.app/AppIcon60x60@2x.png"
    [ -f "$f" ] && FILES="$FILES$f"$'\n'
  done
fi

i=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  app=$(basename "$(dirname "$f")" .app)
  cp "$f" "$OUT/$app.png"
  i=$((i + 1))
done <<< "$FILES"

echo "extracted $i icons to $OUT"
if [ "$i" -eq 0 ]; then
  echo "(none matched — アプリ名は MobileSMS / MobileCal のような内部名で指定する)" >&2
else
  # 実サービス系のバンドル(*ViewService・*Trampoline 等)も混ざるので、
  # 一覧を見て要らないものを消してから grid にかけるとよい。
  echo "(注意: ViewService / Trampoline などユーザーに見えないバンドルも含まれる)"
fi
exit 0
