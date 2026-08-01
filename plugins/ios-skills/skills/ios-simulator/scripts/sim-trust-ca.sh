#!/usr/bin/env bash
# sim-trust-ca.sh — MITM プロキシのルート CA を「その端末にだけ」入れる。
#
# Why(2026-08-01 第2ラウンドの実測): Simulator は **macOS のシステムプロキシ設定を継承する**。
#   Proxyman 等が 127.0.0.1:9090 を HTTPS プロキシに設定していると Simulator の通信も全部 MITM され、
#   新品の Simulator はそのルート CA を信頼していないので HTTPS が丸ごと落ちる:
#     - Safari / アカウント追加で「サーバの識別情報を検証できません」
#     - アプリの通信は静かに失敗(HTTPS だけ落ちるので「サーバーが落ちている」ように見える)
#     - デバイスログに [C47 127.0.0.1:9090 ... proxy ...] → SecTrustEvaluateIfNecessary
#       → Task ... finished with error [-999] の3点セットが出る
#   観測手段(プロキシ)がそのまま被験体を壊す構図なので、踏むと原因究明が長引く。
#
# Why 「端末に CA を入れる」を既定手段にする(グローバル設定を触らない):
#   別の解として「Proxyman 側の SSL Proxying を一時的に切って、終わったら戻す」運用があり、
#   実際に今夜それをやったエージェントがいた。だがこれは
#     (a) **ホスト全体の設定**を書き換えるので、同時に走っている他の作業を壊しうる
#     (b) 戻し忘れると環境が壊れたまま残る(= 次の人が原因不明の症状を踏む)
#   一方 add-root-cert は **その UDID のキーチェーンにしか影響しない**。副作用の範囲が最小で、
#   しかも復号キャプチャもそのまま取れる(プロキシを落として逃げるより実験に有利)。
#   → このスクリプトは **グローバル設定(networksetup / Proxyman の設定)を絶対に変更しない**。
#
# 冪等性: 同じ CA を何度入れても壊れない(エージェントはリトライする前提で書く)。
#   simctl 側が「既に入っている」旨のエラーを返した場合も成功として扱う。
set -uo pipefail   # set -e は使わない: 探索の失敗を「値」として扱いたいため(preflight と同方針)

usage() {
  cat <<'EOF'
Usage: sim-trust-ca.sh --udid <UDID> [--ca <path>] [--dry-run]

MITM プロキシのルート CA を指定 Simulator の信頼ストアに入れる
(実体は `xcrun simctl keychain <UDID> add-root-cert <pem>`)。
**その端末にしか影響しない**。システムプロキシやプロキシアプリの設定は一切変更しない。

Options:
  --udid <UDID>   対象 Simulator の UDID(必須。環境変数 SIM_UDID でも可)
  --ca <path>     CA 証明書(PEM)。省略時は既知の場所を自動探索:
                    1. Proxyman  ~/Library/Application Support/com.proxyman.NSProxy/app-data/proxyman-ca.pem
                    2. Charles   ~/Library/Application Support/Charles/ca/charles-proxy-ssl-proxying-certificate.pem
                    3. mitmproxy ~/.mitmproxy/mitmproxy-ca-cert.pem
  --dry-run       実行せず、使う CA と実行予定のコマンドだけ JSON で返す
  -h, --help      このヘルプ

Output (stdout, JSON):
  {"status":"ok","udid":"...","ca":"...","source":"proxyman","applied":true,"dry_run":false}

Exit codes (このスキルの全スクリプト共通):
  0  成功(冪等。既に入っていても 0)
  2  引数不正(--udid 未指定など)
  3  端末が見つからない / Booted でない / simctl 失敗
  7  CA が見つからない・PEM でない(前提不足)
  ※ 4/5/6(要素なし・タイムアウト・idb)はこのスクリプトでは使わない。

Examples:
  scripts/sim-trust-ca.sh --udid EF5D841C-...
  scripts/sim-trust-ca.sh --udid EF5D841C-... --ca ~/certs/my-ca.pem --dry-run
EOF
}

# ---- 共通の作法(bash 3本で同一実装を意図的に複製) ----------------------------------
err() { printf '%s\n' "$@" >&2; }
json_str() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }
list_booted() {
  xcrun simctl list devices booted 2>/dev/null \
    | sed -n 's/^[[:space:]]*\(.*\) (\([0-9A-Fa-f-]\{20,\}\)) (Booted).*/\2	\1/p'
}
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
# ------------------------------------------------------------------------------------

UDID="${SIM_UDID:-}"
CA=""
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="${2:-}"; shift 2 || true ;;
    --udid=*) UDID="${1#*=}"; shift ;;
    --ca) CA="${2:-}"; shift 2 || true ;;
    --ca=*) CA="${1#*=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "不明な引数: $1" "  → scripts/sim-trust-ca.sh --help で使い方を確認する。"; exit 2 ;;
  esac
done

if [[ -z "$UDID" ]]; then
  err "UDID 未指定。--udid <UDID> か環境変数 SIM_UDID を指定すること。" \
      "  → xcrun simctl list devices booted で対象を確認してから明示する" \
      "    (CA を入れる先を間違えると、症状が消えないまま『対処済み』と誤認する)。"
  exit 2
fi

if ! command -v xcrun >/dev/null 2>&1; then
  err "xcrun が無い。フル Xcode が必要(Command Line Tools だけでは simctl が揃わない)。" \
      "  → xcode-select -p で選択中の開発者ディレクトリを確認する。"
  exit 7
fi

# CA を入れるのは Shutdown でも可能だが、実務上は Booted な端末に対して打つ。
# ここで確認しておくと「UDID の打ち間違い」を simctl の曖昧なエラーより早く潰せる。
BOOTED="$(list_booted)"
if ! printf '%s\n' "$BOOTED" | tr '[:lower:]' '[:upper:]' | grep -qF "$(upper "$UDID")"; then
  err "UDID '$UDID' は Booted な端末として見つからない。" \
      "  → 現在 Booted な端末:" \
      "${BOOTED:-    (なし)}" \
      "  → 起動するなら xcrun simctl boot \"$UDID\"(他人が使っている端末を落とさないこと)。"
  exit 3
fi

# ---- CA の探索 ----------------------------------------------------------------------
# Why この順序: Proxyman は**このリポジトリで実測済み**の経路(既定パスと動作を確認済み)。
#   Charles / mitmproxy のパスは一般に知られた既定値で、こちらは未実測。
#   見つからなければ「どこにあるか」を示して落とす —— 黙って何もしないのが最悪
#   (「対処した」と誤認したまま TLS エラーの原因を探し続けることになる)。
PROXYMAN_CA="$HOME/Library/Application Support/com.proxyman.NSProxy/app-data/proxyman-ca.pem"
CHARLES_CA="$HOME/Library/Application Support/Charles/ca/charles-proxy-ssl-proxying-certificate.pem"
MITM_CA="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"

SOURCE="explicit"
if [[ -z "$CA" ]]; then
  if   [[ -f "$PROXYMAN_CA" ]]; then CA="$PROXYMAN_CA"; SOURCE="proxyman"
  elif [[ -f "$CHARLES_CA"  ]]; then CA="$CHARLES_CA";  SOURCE="charles"
  elif [[ -f "$MITM_CA"     ]]; then CA="$MITM_CA";     SOURCE="mitmproxy"
  else
    err "CA 証明書が見つからない(自動探索した既定パスはいずれも不在)。" \
        "  探索した場所:" \
        "    $PROXYMAN_CA" \
        "    $CHARLES_CA" \
        "    $MITM_CA" \
        "  → Proxyman: Certificate > Export > Root Certificate as PEM で書き出して --ca <path> で渡す。" \
        "  → mitmproxy: 一度起動すると ~/.mitmproxy/ に生成される。" \
        "  → そもそもプロキシを使っていないなら、TLS エラーの原因は別にある。" \
        "    scripts/sim-preflight.sh --udid $UDID で system_proxy_active が出るか確認する。"
    exit 7
  fi
fi

if [[ ! -f "$CA" ]]; then
  err "指定された CA が存在しない: $CA" \
      "  → パスを確認する(~ はクォート内で展開されない点に注意)。"
  exit 7
fi

# PEM でないと add-root-cert は失敗する。DER(.cer)を渡す事故が起きやすいので先に見る。
if ! grep -q -- "-----BEGIN CERTIFICATE-----" "$CA" 2>/dev/null; then
  err "'$CA' は PEM 形式に見えない(-----BEGIN CERTIFICATE----- が無い)。" \
      "  → DER(.cer/.der)なら変換する:" \
      "    openssl x509 -inform der -in \"$CA\" -out \"\${TMPDIR:-\$HOME/tmp-sim/}ca.pem\"" \
      "  → 変換後のパスを --ca で渡してリトライ。"
  exit 7
fi

if (( DRY )); then
  printf '{"status":"dry-run","udid":%s,"ca":%s,"source":%s,"applied":false,"dry_run":true,"command":%s}\n' \
    "$(json_str "$UDID")" "$(json_str "$CA")" "$(json_str "$SOURCE")" \
    "$(json_str "xcrun simctl keychain $UDID add-root-cert $CA")"
  err "dry-run: 実行はしていない。実際に入れるなら --dry-run を外して再実行する。"
  exit 0
fi

# ---- 実行 ---------------------------------------------------------------------------
# `xcrun simctl keychain` のサブコマンドは add-root-cert / add-cert / reset の3つ。
# reset は端末のキーチェーンを消す破壊的操作なので、このスクリプトからは絶対に呼ばない
# (「入れる」だけを提供する = low-freedom。消す必要があるなら人が明示的に打つべき)。
OUT="$(xcrun simctl keychain "$UDID" add-root-cert "$CA" 2>&1)"
RC=$?
if (( RC != 0 )); then
  # 冪等性: 「既に入っている」系のメッセージは成功扱いにする(エージェントはリトライする)。
  if printf '%s' "$OUT" | grep -qiE 'already|exist|duplicate'; then
    printf '{"status":"ok","udid":%s,"ca":%s,"source":%s,"applied":false,"already_trusted":true,"dry_run":false}\n' \
      "$(json_str "$UDID")" "$(json_str "$CA")" "$(json_str "$SOURCE")"
    err "既に信頼済み(no-op)。"
    exit 0
  fi
  err "add-root-cert に失敗(rc=$RC)。" \
      "$OUT" \
      "  → 端末が Booted か再確認: xcrun simctl list devices booted" \
      "  → PEM が壊れていないか: openssl x509 -in \"$CA\" -noout -subject"
  exit 3
fi

printf '{"status":"ok","udid":%s,"ca":%s,"source":%s,"applied":true,"dry_run":false}\n' \
  "$(json_str "$UDID")" "$(json_str "$CA")" "$(json_str "$SOURCE")"
err "CA を $UDID に追加した(source=$SOURCE)。" \
    "  → 反映確認: 端末の Safari で https のサイトを開き、警告が出ないこと。" \
    "  → 既に起動中のアプリは古い信頼設定を掴んでいることがある。疑わしければアプリを再起動する。" \
    "  → グローバル設定(システムプロキシ / プロキシアプリ側)は何も変更していない。"
