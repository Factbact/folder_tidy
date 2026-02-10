#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Verify app version inside a DMG image.

Usage:
  scripts/verify_dmg_version.sh --dmg /path/to/Folder_Tidy_v1.3.1.dmg --expected-version 1.3.1

Optional:
  --app-name "Folder Tidy.app"
USAGE
}

DMG_PATH=""
EXPECTED_VERSION=""
APP_NAME=""
DEVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --expected-version)
      EXPECTED_VERSION="${2:-}"
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
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

if [[ -z "$DMG_PATH" || -z "$EXPECTED_VERSION" ]]; then
  echo "Error: --dmg and --expected-version are required." >&2
  usage
  exit 1
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Error: DMG not found: $DMG_PATH" >&2
  exit 1
fi

cleanup() {
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ATTACH_OUTPUT="$(hdiutil attach "$DMG_PATH" -nobrowse -readonly)"
DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_POINT="$(echo "$ATTACH_OUTPUT" | awk '/\/Volumes\// {for(i=3;i<=NF;i++){printf("%s%s",$i,(i<NF?" ":""))}; print ""; exit}')"

if [[ -z "$DEVICE" || -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
  echo "Error: failed to mount DMG: $DMG_PATH" >&2
  exit 1
fi

if [[ -n "$APP_NAME" ]]; then
  APP_PATH="$MOUNT_POINT/$APP_NAME"
else
  APP_PATH="$(find "$MOUNT_POINT" -maxdepth 1 -mindepth 1 -type d -name '*.app' | head -n 1)"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Error: .app bundle not found in DMG: $DMG_PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/verify_app_version.sh" --app "$APP_PATH" --expected-version "$EXPECTED_VERSION"
echo "OK: DMG contains expected app version $EXPECTED_VERSION ($DMG_PATH)"
