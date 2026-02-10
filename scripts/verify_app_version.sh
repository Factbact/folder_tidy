#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Verify CFBundleShortVersionString in a .app bundle.

Usage:
  scripts/verify_app_version.sh --app /path/to/Folder\ Tidy.app --expected-version 1.3.1
USAGE
}

APP_PATH=""
EXPECTED_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --expected-version)
      EXPECTED_VERSION="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$EXPECTED_VERSION" ]]; then
  echo "Error: --app and --expected-version are required." >&2
  usage
  exit 1
fi

if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "Error: invalid app bundle path: $APP_PATH" >&2
  exit 1
fi

PLIST_PATH="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$PLIST_PATH" ]]; then
  echo "Error: Info.plist not found: $PLIST_PATH" >&2
  exit 1
fi

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH" 2>/dev/null || true)"
if [[ -z "$ACTUAL_VERSION" ]]; then
  echo "Error: CFBundleShortVersionString is missing in $PLIST_PATH" >&2
  exit 1
fi

if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Error: app version mismatch. expected=$EXPECTED_VERSION actual=$ACTUAL_VERSION app=$APP_PATH" >&2
  exit 1
fi

echo "OK: app version is $ACTUAL_VERSION ($APP_PATH)"
