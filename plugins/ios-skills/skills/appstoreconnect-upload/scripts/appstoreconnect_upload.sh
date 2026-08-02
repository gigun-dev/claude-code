#!/usr/bin/env bash

set -uo pipefail

EX_OK=0
EX_USAGE=2
EX_ENV=3
EX_VALIDATE=4
EX_ARCHIVE=10
EX_UPLOAD=11

usage() {
  cat <<'EOF'
Usage: appstoreconnect_upload.sh --project <path> --scheme <scheme> [options]

Validate and print an App Store Connect archive/upload plan. No archive or upload occurs
unless --upload is supplied. Diagnostics go to stderr; stdout is one JSON object.

Options:
  --project <path>       .xcodeproj, .xcworkspace, or directory containing exactly one
  --scheme <name>        Shared scheme to archive
  --export-options <p>   ExportOptions.plist (default: ../assets/ExportOptions.plist)
  --archive-path <p>     Output .xcarchive (default: ./build/<scheme>.xcarchive)
  --export-path <p>      Export working directory (default: ./build/export-<scheme>)
  --destination <d>      Archive destination (default: generic/platform=iOS)
  --configuration <c>    Build configuration (default: Release)
  --allow-provisioning-updates  Pass through to archive and export
  --upload               Execute archive and upload; without this flag, plan only
  -h, --help             Show this help

Exit codes:
  0 success/valid plan; 2 invalid arguments; 3 missing dependency/environment;
  4 validation error; 10 archive failed; 11 export/upload failed.
EOF
}

diag() { printf '%s\n' "$*" >&2; }
fail() { local code="$1"; shift; diag "error: $*"; exit "$code"; }
emit_json() {
  python3 - "$@" <<'PY'
import json, sys
keys = ["status", "mode", "project", "scheme", "configuration", "destination",
        "archive_path", "export_path", "export_options", "allow_provisioning_updates", "log_path"]
obj = {k: sys.argv[i + 1] for i, k in enumerate(keys)}
obj["allow_provisioning_updates"] = obj["allow_provisioning_updates"] == "true"
print(json.dumps(obj, ensure_ascii=False))
PY
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH=""
SCHEME=""
EXPORT_OPTIONS="$SCRIPT_DIR/../assets/ExportOptions.plist"
ARCHIVE_PATH=""
EXPORT_PATH=""
DESTINATION="generic/platform=iOS"
CONFIGURATION="Release"
ALLOW_UPDATES=false
UPLOAD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--project requires a path"; PROJECT_PATH="$2"; shift 2 ;;
    --scheme) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--scheme requires a name"; SCHEME="$2"; shift 2 ;;
    --export-options) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--export-options requires a path"; EXPORT_OPTIONS="$2"; shift 2 ;;
    --archive-path) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--archive-path requires a path"; ARCHIVE_PATH="$2"; shift 2 ;;
    --export-path) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--export-path requires a path"; EXPORT_PATH="$2"; shift 2 ;;
    --destination) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--destination requires a value"; DESTINATION="$2"; shift 2 ;;
    --configuration) [[ $# -ge 2 ]] || fail "$EX_USAGE" "--configuration requires a value"; CONFIGURATION="$2"; shift 2 ;;
    --allow-provisioning-updates) ALLOW_UPDATES=true; shift ;;
    --upload) UPLOAD=true; shift ;;
    -h|--help) usage; exit "$EX_OK" ;;
    *) fail "$EX_USAGE" "unknown argument: $1" ;;
  esac
done

[[ -n "$PROJECT_PATH" ]] || fail "$EX_USAGE" "--project is required"
[[ -n "$SCHEME" ]] || fail "$EX_USAGE" "--scheme is required"
command -v xcodebuild >/dev/null 2>&1 || fail "$EX_ENV" "xcodebuild not found; select full Xcode"
command -v python3 >/dev/null 2>&1 || fail "$EX_ENV" "python3 not found"
command -v plutil >/dev/null 2>&1 || fail "$EX_ENV" "plutil not found"

PROJECT_PATH="$(cd "$(dirname "$PROJECT_PATH")" 2>/dev/null && pwd)/$(basename "$PROJECT_PATH")" ||
  fail "$EX_VALIDATE" "project path does not exist: $PROJECT_PATH"
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
  [[ ${#candidates[@]} -eq 1 ]] || fail "$EX_VALIDATE" "directory must contain exactly one workspace or project"
  BUILD_FILE="${candidates[0]}"
  [[ "$BUILD_FILE" == *.xcworkspace ]] && BUILD_KIND="-workspace" || BUILD_KIND="-project"
else
  fail "$EX_VALIDATE" "--project must point to a .xcodeproj, .xcworkspace, or directory"
fi

PROJECT_ROOT="$(dirname "$BUILD_FILE")"
[[ "$EXPORT_OPTIONS" = /* ]] || EXPORT_OPTIONS="$PROJECT_ROOT/$EXPORT_OPTIONS"
EXPORT_OPTIONS="$(cd "$(dirname "$EXPORT_OPTIONS")" 2>/dev/null && pwd)/$(basename "$EXPORT_OPTIONS")" ||
  fail "$EX_VALIDATE" "ExportOptions.plist does not exist: $EXPORT_OPTIONS"
plutil -lint "$EXPORT_OPTIONS" >/dev/null || fail "$EX_VALIDATE" "invalid ExportOptions.plist: $EXPORT_OPTIONS"

[[ -n "$ARCHIVE_PATH" ]] || ARCHIVE_PATH="$PROJECT_ROOT/build/${SCHEME}.xcarchive"
[[ -n "$EXPORT_PATH" ]] || EXPORT_PATH="$PROJECT_ROOT/build/export-${SCHEME}"
[[ "$ARCHIVE_PATH" = /* ]] || ARCHIVE_PATH="$PROJECT_ROOT/$ARCHIVE_PATH"
[[ "$EXPORT_PATH" = /* ]] || EXPORT_PATH="$PROJECT_ROOT/$EXPORT_PATH"

if "$UPLOAD"; then
  METHOD="$(plutil -extract method raw -o - "$EXPORT_OPTIONS" 2>/dev/null || true)"
  EXPORT_DESTINATION="$(plutil -extract destination raw -o - "$EXPORT_OPTIONS" 2>/dev/null || true)"
  [[ "$METHOD" == "app-store-connect" ]] || fail "$EX_VALIDATE" "--upload requires ExportOptions method=app-store-connect (found: ${METHOD:-missing})"
  [[ "$EXPORT_DESTINATION" == "upload" ]] || fail "$EX_VALIDATE" "--upload requires ExportOptions destination=upload (found: ${EXPORT_DESTINATION:-missing})"
  [[ ! -e "$ARCHIVE_PATH" ]] || fail "$EX_VALIDATE" "archive path already exists; choose a new path: $ARCHIVE_PATH"
  [[ ! -e "$EXPORT_PATH" ]] || fail "$EX_VALIDATE" "export path already exists; choose a new path: $EXPORT_PATH"
else
  emit_json "ok" "plan" "$BUILD_FILE" "$SCHEME" "$CONFIGURATION" "$DESTINATION" "$ARCHIVE_PATH" "$EXPORT_PATH" "$EXPORT_OPTIONS" "$ALLOW_UPDATES" ""
  exit "$EX_OK"
fi

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$(dirname "$EXPORT_PATH")" || fail "$EX_ENV" "cannot create output parent directories"
provisioning_args=()
"$ALLOW_UPDATES" && provisioning_args+=("-allowProvisioningUpdates")

diag "archiving $SCHEME to $ARCHIVE_PATH"
LOG_PATH="$(mktemp "${TMPDIR:-/tmp}/appstoreconnect-upload.log.XXXXXX")" || fail "$EX_ENV" "cannot create log file"
if ! xcodebuild archive "$BUILD_KIND" "$BUILD_FILE" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" -archivePath "$ARCHIVE_PATH" \
    -destination "$DESTINATION" "${provisioning_args[@]}" >"$LOG_PATH" 2>&1; then
  tail -80 "$LOG_PATH" >&2
  diag "full archive/upload log: $LOG_PATH"
  fail "$EX_ARCHIVE" "archive failed; inspect the xcodebuild diagnostics above"
fi
diag "archive succeeded"

diag "exporting and uploading to App Store Connect"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" -exportPath "$EXPORT_PATH" \
    "${provisioning_args[@]}" >>"$LOG_PATH" 2>&1; then
  tail -80 "$LOG_PATH" >&2
  diag "full archive/upload log: $LOG_PATH"
  fail "$EX_UPLOAD" "export/upload failed; archive remains at $ARCHIVE_PATH"
fi
diag "upload command succeeded; log: $LOG_PATH"

emit_json "ok" "upload" "$BUILD_FILE" "$SCHEME" "$CONFIGURATION" "$DESTINATION" "$ARCHIVE_PATH" "$EXPORT_PATH" "$EXPORT_OPTIONS" "$ALLOW_UPDATES" "$LOG_PATH"
