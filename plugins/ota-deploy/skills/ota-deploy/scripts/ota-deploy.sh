#!/usr/bin/env bash
#
# ota-deploy.sh — build an iOS (.ipa) and/or Android (.apk) and publish an
# install page over Tailscale, so you can install builds on your phone from a
# browser. No TestFlight, no Play Console, no ASC.
#
# Usage:
#   ota-deploy.sh [CONFIG]                # build per config (default: ./ota.conf)
#   ota-deploy.sh myapp.conf              # build using a specific config file
#   ota-deploy.sh -m "note"              # override this build's changelog text
#   ota-deploy.sh --ios                   # only build iOS this run
#   ota-deploy.sh --android               # only build Android this run
#   ota-deploy.sh --ipa path/to/App.ipa   # skip xcodebuild, use a prebuilt ipa
#   ota-deploy.sh --apk path/to/app.apk   # skip gradle, use a prebuilt apk
#   ota-deploy.sh --serve-only            # just (re)start serving (e.g. after reboot)
#
# See README.md for full setup + customization.
#
set -euo pipefail

# ---- locate + load config ----------------------------------------------
CONFIG=""; SERVE_ONLY=0; ONLY=""; IPA_OVERRIDE=""; APK_OVERRIDE=""; MSG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --serve-only) SERVE_ONLY=1; shift;;
    --ios) ONLY="ios"; shift;;
    --android) ONLY="android"; shift;;
    --ipa) IPA_OVERRIDE="$2"; shift 2;;
    --apk) APK_OVERRIDE="$2"; shift 2;;
    -m|--message) MSG="$2"; shift 2;;
    -*) echo "unknown flag: $1" >&2; exit 2;;
    *) CONFIG="$1"; shift;;
  esac
done
[ -z "$CONFIG" ] && CONFIG="./ota.conf"
if [ ! -f "$CONFIG" ]; then
  echo "✖ config not found: $CONFIG  (copy ota.conf.example → ota.conf and edit)" >&2
  exit 1
fi

# ---- defaults (overridable in the config) ------------------------------
APP_NAME="App"; APP_SLUG=""; PLATFORMS="ios"
TS_HOST=""; PORT="8787"
IOS_PROJECT=""; IOS_WORKSPACE=""; IOS_SCHEME=""; IOS_BUNDLE_ID=""
IOS_TEAM_ID=""; IOS_EXPORT_METHOD="release-testing"
ANDROID_PROJECT_DIR=""; ANDROID_GRADLE_TASK=":app:assembleDebug"
ANDROID_APK_GLOB="app/build/outputs/apk/debug/*.apk"
# custom build hooks (Mode B — any framework: Flutter, MAUI, Unity, Tauri, …)
PRE_BUILD=""; PRE_BUILD_DIR=""
IOS_BUILD_CMD=""; IOS_BUILD_DIR=""; IOS_IPA_GLOB=""
ANDROID_BUILD_CMD=""; ANDROID_BUILD_DIR=""
GIT_REPO=""; TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
# shellcheck disable=SC1090
source "$CONFIG"

[ -z "$TS_HOST" ] && { echo "✖ TS_HOST is required in $CONFIG" >&2; exit 1; }
[ -n "$ONLY" ] && PLATFORMS="$ONLY"

# slug → URL path + state dir; default = sanitized app name
[ -z "$APP_SLUG" ] && APP_SLUG="$(printf '%s' "$APP_NAME" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
[ -z "$GIT_REPO" ] && GIT_REPO="${ANDROID_PROJECT_DIR:-$(dirname "${IOS_PROJECT:-${IOS_WORKSPACE:-.}}")}"

# ---- paths --------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OTA_HOME="${OTA_HOME:-$HOME/.ota-deploy}"
PUB_ROOT="$OTA_HOME/public"               # one server serves this for ALL projects
PUBLIC="$PUB_ROOT/$APP_SLUG"              # this project's files live under /<slug>/
STATE="$OTA_HOME/state/$APP_SLUG"
TS_BIN="$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)"
BASE_URL="https://$TS_HOST/$APP_SLUG"
mkdir -p "$PUBLIC" "$STATE"

# ---- serve: local static server + tailscale proxy ----------------------
serve() {
  echo "→ Serving $PUB_ROOT over Tailscale HTTPS…"
  # macOS GUI Tailscale can't serve a filesystem path (sandbox); proxy to a
  # local static server instead. One server covers every project's subfolder.
  if ! curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    ( cd "$PUB_ROOT" && nohup python3 -m http.server "$PORT" --bind 127.0.0.1 >/tmp/ota-deploy-http.log 2>&1 & )
    sleep 1
  fi
  "$TS_BIN" serve --bg "$PORT" >/dev/null 2>&1 || true
  echo "   $BASE_URL/"
}

if [ "$SERVE_ONLY" = "1" ]; then serve; exit 0; fi

# ---- build number (auto-increment, per project) ------------------------
COUNTER="$STATE/build-number"
BUILD=$(( $( [ -f "$COUNTER" ] && cat "$COUNTER" || echo 0 ) + 1 ))
WORK="$STATE/.work"; rm -rf "$WORK"; mkdir -p "$WORK"
BUILT=""

build_ios() {
  if [ -n "$IPA_OVERRIDE" ]; then
    echo "→ iOS: using prebuilt ipa $IPA_OVERRIDE"
    cp "$IPA_OVERRIDE" "$PUBLIC/app.ipa"
  elif [ -n "$IOS_BUILD_CMD" ]; then
    local ios_dir ios_ipa
    ios_dir="${IOS_BUILD_DIR:-$GIT_REPO}"
    [ -n "$IOS_IPA_GLOB" ] || { echo "✖ IOS_IPA_GLOB required when IOS_BUILD_CMD is set" >&2; return 1; }
    echo "→ iOS: running IOS_BUILD_CMD in $ios_dir"
    ( cd "$ios_dir" && eval "$IOS_BUILD_CMD" )
    ios_ipa="$(ls -t $ios_dir/$IOS_IPA_GLOB 2>/dev/null | head -1)"
    [ -n "$ios_ipa" ] || { echo "✖ no .ipa found at $IOS_IPA_GLOB (in $ios_dir)" >&2; return 1; }
    cp "$ios_ipa" "$PUBLIC/app.ipa"
  else
    [ -n "$IOS_SCHEME" ] || { echo "✖ IOS_SCHEME required for iOS build" >&2; return 1; }
    local proj=()
    if [ -n "$IOS_WORKSPACE" ]; then proj=(-workspace "$IOS_WORKSPACE"); else proj=(-project "$IOS_PROJECT"); fi
    echo "→ iOS: archiving $IOS_SCHEME (build $BUILD)…"
    xcodebuild "${proj[@]}" -scheme "$IOS_SCHEME" -configuration Release \
      -destination 'generic/platform=iOS' -archivePath "$WORK/app.xcarchive" \
      CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates archive
    cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>method</key><string>$IOS_EXPORT_METHOD</string>
  <key>teamID</key><string>$IOS_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
</dict></plist>
PLIST
    echo "→ iOS: exporting ad-hoc ipa…"
    xcodebuild -exportArchive -archivePath "$WORK/app.xcarchive" \
      -exportPath "$WORK/export" -exportOptionsPlist "$WORK/ExportOptions.plist" \
      -allowProvisioningUpdates
    cp "$WORK/export/"*.ipa "$PUBLIC/app.ipa"
  fi
  # OTA manifest (iOS reads this to install)
  cat > "$PUBLIC/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>items</key><array><dict>
  <key>assets</key><array><dict>
    <key>kind</key><string>software-package</string>
    <key>url</key><string>$BASE_URL/app.ipa</string>
  </dict></array>
  <key>metadata</key><dict>
    <key>bundle-identifier</key><string>$IOS_BUNDLE_ID</string>
    <key>bundle-version</key><string>$BUILD</string>
    <key>kind</key><string>software</string>
    <key>title</key><string>$APP_NAME</string>
  </dict>
</dict></array></dict></plist>
PLIST
  BUILT="$BUILT ios"
}

build_android() {
  if [ -n "$APK_OVERRIDE" ]; then
    echo "→ Android: using prebuilt apk $APK_OVERRIDE"
    cp "$APK_OVERRIDE" "$PUBLIC/app.apk"
  elif [ -n "$ANDROID_BUILD_CMD" ]; then
    local adir capk
    adir="${ANDROID_BUILD_DIR:-${ANDROID_PROJECT_DIR:-$GIT_REPO}}"
    echo "→ Android: running ANDROID_BUILD_CMD in $adir"
    ( cd "$adir" && eval "$ANDROID_BUILD_CMD" )
    capk="$(ls -t $adir/$ANDROID_APK_GLOB 2>/dev/null | head -1)"
    [ -n "$capk" ] || { echo "✖ no APK found at $ANDROID_APK_GLOB (in $adir)" >&2; return 1; }
    cp "$capk" "$PUBLIC/app.apk"
  else
    [ -n "$ANDROID_PROJECT_DIR" ] || { echo "✖ ANDROID_PROJECT_DIR required for Android build" >&2; return 1; }
    echo "→ Android: $ANDROID_GRADLE_TASK …"
    ( cd "$ANDROID_PROJECT_DIR" && ./gradlew $ANDROID_GRADLE_TASK )
    local apk
    apk="$(ls -t $ANDROID_PROJECT_DIR/$ANDROID_APK_GLOB 2>/dev/null | head -1)"
    [ -n "$apk" ] || { echo "✖ no APK found at $ANDROID_APK_GLOB" >&2; return 1; }
    cp "$apk" "$PUBLIC/app.apk"
  fi
  BUILT="$BUILT android"
}

if [ -n "$PRE_BUILD" ]; then
  pre_dir="${PRE_BUILD_DIR:-$GIT_REPO}"
  echo "→ pre-build: $PRE_BUILD (in $pre_dir)"
  ( cd "$pre_dir" && eval "$PRE_BUILD" )
fi

for p in $PLATFORMS; do
  case "$p" in
    ios) build_ios;;
    android) build_android;;
    *) echo "⚠ unknown platform '$p' in PLATFORMS" >&2;;
  esac
done
[ -n "$BUILT" ] || { echo "✖ nothing built" >&2; exit 1; }
echo "$BUILD" > "$COUNTER"

# ---- changelog: auto from git log since the previous build --------------
LOG="$STATE/builds.tsv"; touch "$LOG"
DATE="$(date '+%b %-d, %-H:%M')"
HEAD_SHA="$(git -C "$GIT_REPO" rev-parse --short HEAD 2>/dev/null || echo '')"
LAST_SHA="$(tail -1 "$LOG" | cut -f3)"
if [ -n "$MSG" ]; then COMMITS="$MSG"
elif [ -z "$HEAD_SHA" ]; then COMMITS="New build"
elif [ -z "$LAST_SHA" ]; then COMMITS="$(git -C "$GIT_REPO" log -5 --pretty=%s)"
else
  COMMITS="$(git -C "$GIT_REPO" log "${LAST_SHA}..HEAD" --pretty=%s 2>/dev/null)"
  [ -z "$COMMITS" ] && COMMITS="(no new commits since build $(tail -1 "$LOG" | cut -f1))"
fi
JOINED="$(printf '%s\n' "$COMMITS" | awk 'NF{a=a sep $0; sep=" ||| "} END{print a}')"
printf '%s\t%s\t%s\t%s\n' "$BUILD" "$DATE" "$HEAD_SHA" "$JOINED" >> "$LOG"

# ---- render install page -----------------------------------------------
export APP_NAME BUILD DATE TS_HOST APP_SLUG IOS_BUNDLE_ID BASE_URL
python3 - "$SELF_DIR/template.html" "$PUBLIC/index.html" "$LOG" "$PUBLIC" <<'PY'
import sys, os, html
tmpl, out, logf, pub = sys.argv[1:5]
host, slug, base = os.environ["TS_HOST"], os.environ["APP_SLUG"], os.environ["BASE_URL"]

# action buttons depend on which artifacts exist
actions = []
if os.path.exists(os.path.join(pub, "app.ipa")):
    man = "itms-services://?action=download-manifest&amp;url=%s/manifest.plist" % base
    actions.append('<a class="btn ios" href="%s">Install on iPhone</a>' % man)
    actions.append('<p class="hint">Open in <b>Safari</b>. After installing: '
                   '<b>Settings → General → VPN &amp; Device Management</b> → trust the developer.</p>')
if os.path.exists(os.path.join(pub, "app.apk")):
    actions.append('<a class="btn android" href="%s/app.apk">Download for Android</a>' % base)
    actions.append('<p class="hint">Open in <b>Chrome</b>, tap the downloaded APK to install. '
                   'Allow <b>install unknown apps</b> if prompted.</p>')

# changelog: last 10 builds, newest first
rows = []
for line in open(logf):
    p = line.rstrip("\n").split("\t")
    if len(p) >= 4: rows.append(p[:4])
blocks = []
for b, d, sha, joined in rows[-10:][::-1]:
    when = html.escape(d) + (" · " + html.escape(sha) if sha else "")
    items = [c.strip() for c in joined.split("|||") if c.strip()]
    lis = "".join("<li>%s</li>" % html.escape(c) for c in items) or "<li>—</li>"
    blocks.append('<div class="change"><div class="b">Build %s<span class="when">%s</span></div>'
                  '<ul class="body">%s</ul></div>' % (html.escape(b), when, lis))

repl = {
  "{{APP_NAME}}": html.escape(os.environ["APP_NAME"]),
  "{{INITIAL}}": html.escape(os.environ["APP_NAME"][:1].upper() or "A"),
  "{{BUILD}}": html.escape(os.environ["BUILD"]),
  "{{DATE}}": html.escape(os.environ["DATE"]),
  "{{ACTIONS}}": "\n".join(actions),
  "{{CHANGELOG}}": "\n".join(blocks),
  "{{FOOTER}}": html.escape(os.environ.get("IOS_BUNDLE_ID") or slug) + " · served over Tailscale",
}
h = open(tmpl).read()
for k, v in repl.items(): h = h.replace(k, v)
open(out, "w").write(h)
PY

serve
echo ""
echo "✅ Build $BUILD ready ($(echo "$BUILT" | xargs)) → $BASE_URL/"

# ---- optional Telegram ping --------------------------------------------
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
  curl -fsS "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=📲 $APP_NAME Build $BUILD ready ($(echo "$BUILT" | xargs))
$BASE_URL/" >/dev/null && echo "→ Pinged Telegram" || echo "⚠ Telegram ping failed"
fi
