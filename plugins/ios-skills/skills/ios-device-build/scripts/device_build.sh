#!/usr/bin/env bash

set -uo pipefail

EX_OK=0
EX_USAGE=2
EX_ENV=3
EX_DISCOVERY=4
EX_BUILD=10
EX_INSTALL=11
EX_LAUNCH=12

usage() {
  cat <<'EOF'
Usage:
  device_build.sh --list-devices
  device_build.sh --project <path> --scheme <scheme> --device <UDID> [options]

Build, install, and optionally launch an iOS app on one explicitly selected device.
Human-readable diagnostics go to stderr; the final result goes to stdout as JSON.

Options:
  --project <path>    .xcodeproj, .xcworkspace, or a directory containing exactly one
  --scheme <name>     Shared Xcode scheme to build (required for build)
  --device <UDID>     Physical-device UDID (or set IOS_DEVICE_UDID)
  --bundle-id <id>    Bundle identifier override; otherwise read from built Info.plist
  --configuration <c> Build configuration (default: Debug)
  --derived-data <p>  Fresh/nonexistent DerivedData path (default: a new temporary path)
  --list-devices      Return paired devices as JSON; perform no build
  --dry-run           Validate and emit the plan without building/installing/launching
  --no-launch         Build and install, but do not launch
  -h, --help          Show this help

Exit codes:
  0 success; 2 invalid arguments; 3 missing dependency/environment; 4 discovery error;
  10 build failed; 11 install failed; 12 launch failed.
EOF
}

diag() { printf '%s\n' "$*" >&2; }
fail() { local code="$1"; shift; diag "error: $*"; exit "$code"; }

json_result() {
  python3 - "$@" <<'PY'
import json, sys
keys = ["status", "action", "project", "scheme", "device_udid", "device_name",
        "configuration", "derived_data", "app_path", "bundle_id", "launched", "log_path"]
values = sys.argv[1:]
obj = {k: (values[i] if i < len(values) and values[i] else None) for i, k in enumerate(keys)}
if obj["launched"] is not None:
    obj["launched"] = obj["launched"] == "true"
print(json.dumps(obj, ensure_ascii=False))
PY
}

PROJECT_PATH=""
SCHEME=""
DEVICE_UDID="${IOS_DEVICE_UDID:-}"
BUNDLE_ID=""
CONFIGURATION="Debug"
DERIVED_DATA=""
LIST_DEVICES=false
DRY_RUN=false
NO_LAUNCH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--project requires a path"; PROJECT_PATH="$2"; shift 2 ;;
    --scheme) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--scheme requires a name"; SCHEME="$2"; shift 2 ;;
    --device) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--device requires a UDID"; DEVICE_UDID="$2"; shift 2 ;;
    --bundle-id) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--bundle-id requires a value"; BUNDLE_ID="$2"; shift 2 ;;
    --configuration) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--configuration requires a value"; CONFIGURATION="$2"; shift 2 ;;
    --derived-data) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--derived-data requires a path"; DERIVED_DATA="$2"; shift 2 ;;
    --list-devices) LIST_DEVICES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-launch) NO_LAUNCH=true; shift ;;
    -h|--help) usage; exit "$EX_OK" ;;
    *) fail "$EX_USAGE" "unknown argument: $1" ;;
  esac
done

command -v xcrun >/dev/null 2>&1 || fail "$EX_ENV" "xcrun not found; install full Xcode"
command -v python3 >/dev/null 2>&1 || fail "$EX_ENV" "python3 not found"

DEVICE_JSON=""
cleanup() { [[ -n "$DEVICE_JSON" ]] && rm -f "$DEVICE_JSON"; }
trap cleanup EXIT
if "$LIST_DEVICES" || ! "$DRY_RUN"; then
  DEVICE_JSON="$(mktemp "${TMPDIR:-/tmp}/ios-device-list.XXXXXX")" || fail "$EX_ENV" "cannot create temporary file"
  if ! xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1; then
    fail "$EX_DISCOVERY" "devicectl could not list devices; connect and unlock the device"
  fi
fi

if "$LIST_DEVICES"; then
  python3 - "$DEVICE_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    raw = f.read()
data = json.loads(raw[raw.find("{"):])
devices = []
for d in data.get("result", {}).get("devices", []):
    if d.get("connectionProperties", {}).get("pairingState") != "paired":
        continue
    devices.append({
        "udid": d.get("hardwareProperties", {}).get("udid"),
        "name": d.get("deviceProperties", {}).get("name"),
        "connection": d.get("connectionProperties", {}).get("transportType"),
    })
print(json.dumps({"status": "ok", "devices": devices}, ensure_ascii=False))
PY
  exit "$EX_OK"
fi

[[ -n "$PROJECT_PATH" ]] || fail "$EX_USAGE" "--project is required"
[[ -n "$SCHEME" ]] || fail "$EX_USAGE" "--scheme is required"
[[ -n "$DEVICE_UDID" ]] || fail "$EX_USAGE" "--device <UDID> or IOS_DEVICE_UDID is required; use --list-devices"
command -v xcodebuild >/dev/null 2>&1 || fail "$EX_ENV" "xcodebuild not found; select full Xcode with xcode-select"

DEVICE_NAME=""
if ! "$DRY_RUN"; then
  DEVICE_NAME="$(python3 - "$DEVICE_JSON" "$DEVICE_UDID" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    raw = f.read()
data = json.loads(raw[raw.find("{"):])
wanted = sys.argv[2]
for d in data.get("result", {}).get("devices", []):
    if d.get("connectionProperties", {}).get("pairingState") != "paired":
        continue
    if d.get("hardwareProperties", {}).get("udid") == wanted:
        print(d.get("deviceProperties", {}).get("name", ""))
        break
PY
)"
  [[ -n "$DEVICE_NAME" ]] || fail "$EX_DISCOVERY" "paired device not found for UDID: $DEVICE_UDID"
fi

PROJECT_PATH="$(cd "$(dirname "$PROJECT_PATH")" 2>/dev/null && pwd)/$(basename "$PROJECT_PATH")" ||
  fail "$EX_DISCOVERY" "project path does not exist: $PROJECT_PATH"
BUILD_KIND=""
BUILD_FILE=""
if [[ -d "$PROJECT_PATH" && "$PROJECT_PATH" == *.xcworkspace ]]; then
  BUILD_KIND="-workspace"; BUILD_FILE="$PROJECT_PATH"
elif [[ -d "$PROJECT_PATH" && "$PROJECT_PATH" == *.xcodeproj ]]; then
  BUILD_KIND="-project"; BUILD_FILE="$PROJECT_PATH"
elif [[ -d "$PROJECT_PATH" ]]; then
  candidates=()
  while IFS= read -r item; do candidates+=("$item"); done < <(find "$PROJECT_PATH" -maxdepth 1 -type d -name '*.xcworkspace' -print | sort)
  if [[ ${#candidates[@]} -eq 0 ]]; then
    while IFS= read -r item; do candidates+=("$item"); done < <(find "$PROJECT_PATH" -maxdepth 1 -type d -name '*.xcodeproj' -print | sort)
  fi
  [[ ${#candidates[@]} -eq 1 ]] || fail "$EX_DISCOVERY" "directory must contain exactly one workspace or project; pass its path explicitly"
  BUILD_FILE="${candidates[0]}"
  [[ "$BUILD_FILE" == *.xcworkspace ]] && BUILD_KIND="-workspace" || BUILD_KIND="-project"
else
  fail "$EX_DISCOVERY" "--project must point to a .xcodeproj, .xcworkspace, or directory"
fi

PROJECT_ROOT="$(dirname "$BUILD_FILE")"
if "$DRY_RUN"; then
  if [[ -z "$DERIVED_DATA" ]]; then
    DERIVED_DATA="${TMPDIR:-/tmp}/ios-device-derived-data.<created-at-execution>"
  else
    DERIVED_DATA="$(python3 - "$PROJECT_ROOT" "$DERIVED_DATA" <<'PY'
import os, sys
root, path = sys.argv[1:]
print(os.path.abspath(path if os.path.isabs(path) else os.path.join(root, path)))
PY
)"
  fi
elif [[ -z "$DERIVED_DATA" ]]; then
  DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/ios-device-derived-data.XXXXXX")" || fail "$EX_ENV" "cannot create DerivedData directory"
else
  [[ "$DERIVED_DATA" = /* ]] || DERIVED_DATA="$PROJECT_ROOT/$DERIVED_DATA"
  [[ ! -e "$DERIVED_DATA" ]] || fail "$EX_USAGE" "--derived-data must not already exist (prevents stale .app selection): $DERIVED_DATA"
  mkdir -p "$DERIVED_DATA" || fail "$EX_ENV" "cannot create DerivedData path: $DERIVED_DATA"
  DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
fi

if [[ -n "$DEVICE_NAME" ]]; then diag "device: $DEVICE_NAME ($DEVICE_UDID)"; else diag "device UDID (not probed in dry-run): $DEVICE_UDID"; fi
diag "project: $BUILD_FILE; scheme: $SCHEME; DerivedData: $DERIVED_DATA"
if "$DRY_RUN"; then
  json_result "ok" "plan" "$BUILD_FILE" "$SCHEME" "$DEVICE_UDID" "$DEVICE_NAME" "$CONFIGURATION" "$DERIVED_DATA" "" "$BUNDLE_ID" "false" ""
  exit "$EX_OK"
fi

diag "building for physical device"
BUILD_LOG="$DERIVED_DATA/device-build.log"
if ! xcodebuild "$BUILD_KIND" "$BUILD_FILE" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -destination "id=$DEVICE_UDID" -derivedDataPath "$DERIVED_DATA" build >"$BUILD_LOG" 2>&1; then
  tail -80 "$BUILD_LOG" >&2
  diag "full build log: $BUILD_LOG"
  fail "$EX_BUILD" "xcodebuild failed"
fi
diag "build succeeded; log: $BUILD_LOG"

PRODUCTS_DIR="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos"
apps=()
if [[ -d "$PRODUCTS_DIR" ]]; then
  while IFS= read -r item; do apps+=("$item"); done < <(find "$PRODUCTS_DIR" -maxdepth 1 -type d -name '*.app' -print | sort)
fi
[[ ${#apps[@]} -gt 0 ]] || fail "$EX_BUILD" "no .app found in fresh DerivedData: $PRODUCTS_DIR"

APP_PATH=""
if [[ -n "$BUNDLE_ID" ]]; then
  for candidate in "${apps[@]}"; do
    candidate_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Info.plist" 2>/dev/null || true)"
    [[ "$candidate_id" == "$BUNDLE_ID" ]] && APP_PATH="$candidate" && break
  done
  [[ -n "$APP_PATH" ]] || fail "$EX_BUILD" "no built app matches bundle id: $BUNDLE_ID"
else
  [[ ${#apps[@]} -eq 1 ]] || fail "$EX_BUILD" "multiple .app products found; rerun with --bundle-id"
  APP_PATH="${apps[0]}"
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || true)"
  [[ -n "$BUNDLE_ID" ]] || fail "$EX_BUILD" "CFBundleIdentifier missing from built app"
fi

diag "installing: $APP_PATH"
if ! xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH" >&2; then
  fail "$EX_INSTALL" "device installation failed"
fi

LAUNCHED=false
if ! "$NO_LAUNCH"; then
  diag "launching: $BUNDLE_ID"
  if ! xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID" >&2; then
    fail "$EX_LAUNCH" "device launch failed"
  fi
  LAUNCHED=true
fi

json_result "ok" "execute" "$BUILD_FILE" "$SCHEME" "$DEVICE_UDID" "$DEVICE_NAME" "$CONFIGURATION" "$DERIVED_DATA" "$APP_PATH" "$BUNDLE_ID" "$LAUNCHED" "$BUILD_LOG"
