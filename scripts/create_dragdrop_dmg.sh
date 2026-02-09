#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Create a drag-and-drop DMG for macOS app distribution.

Usage:
  scripts/create_dragdrop_dmg.sh --app /path/to/Folder\ Tidy.app \
    [--output /path/to/Folder-Tidy.dmg] \
    [--volume-name "Folder Tidy"] \
    [--background /path/to/background.png]

Notes:
- The DMG includes an Applications alias for drag-and-drop install.
- If --background is given, the image is used as Finder window background.
USAGE
}

APP_PATH=""
OUTPUT_DMG=""
VOLUME_NAME=""
BACKGROUND_IMAGE=""

WINDOW_LEFT=120
WINDOW_TOP=120
WINDOW_WIDTH=620
WINDOW_HEIGHT=420
APP_POSITION_X=170
APP_POSITION_Y=200
APPS_POSITION_X=450
APPS_POSITION_Y=200

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DMG="${2:-}"
      shift 2
      ;;
    --volume-name)
      VOLUME_NAME="${2:-}"
      shift 2
      ;;
    --background)
      BACKGROUND_IMAGE="${2:-}"
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

if [[ -z "$APP_PATH" ]]; then
  echo "Error: --app is required." >&2
  usage
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: app path does not exist: $APP_PATH" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
if [[ "$APP_NAME" != *.app ]]; then
  echo "Error: --app must point to a .app bundle." >&2
  exit 1
fi

if [[ -z "$VOLUME_NAME" ]]; then
  VOLUME_NAME="${APP_NAME%.app}"
fi

if [[ -z "$OUTPUT_DMG" ]]; then
  OUTPUT_DMG="$(pwd)/${VOLUME_NAME}.dmg"
fi

if [[ "$OUTPUT_DMG" != *.dmg ]]; then
  OUTPUT_DMG="${OUTPUT_DMG}.dmg"
fi

if [[ -n "$BACKGROUND_IMAGE" && ! -f "$BACKGROUND_IMAGE" ]]; then
  echo "Error: background image does not exist: $BACKGROUND_IMAGE" >&2
  exit 1
fi

if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
  echo "Error: /Volumes/$VOLUME_NAME already exists. Eject it and retry." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d /tmp/folder_tidy_dmg.XXXXXX)"
STAGE_DIR="$WORK_DIR/stage"
RW_DMG="$WORK_DIR/temp.dmg"
DEVICE=""

cleanup() {
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

BG_BASENAME=""
if [[ -n "$BACKGROUND_IMAGE" ]]; then
  BG_BASENAME="$(basename "$BACKGROUND_IMAGE")"
  mkdir -p "$STAGE_DIR/.background"
  cp "$BACKGROUND_IMAGE" "$STAGE_DIR/.background/$BG_BASENAME"
fi

SIZE_MB="$(du -sm "$STAGE_DIR" | awk '{print $1 + 80}')"
hdiutil create -quiet \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDRW \
  -size "${SIZE_MB}m" \
  "$RW_DMG"

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_POINT="/Volumes/$VOLUME_NAME"

if [[ -z "$DEVICE" || ! -d "$MOUNT_POINT" ]]; then
  echo "Error: failed to mount writable DMG." >&2
  exit 1
fi

WINDOW_RIGHT=$((WINDOW_LEFT + WINDOW_WIDTH))
WINDOW_BOTTOM=$((WINDOW_TOP + WINDOW_HEIGHT))

if ! osascript - \
  "$VOLUME_NAME" \
  "$APP_NAME" \
  "$BG_BASENAME" \
  "$WINDOW_LEFT" \
  "$WINDOW_TOP" \
  "$WINDOW_RIGHT" \
  "$WINDOW_BOTTOM" \
  "$APP_POSITION_X" \
  "$APP_POSITION_Y" \
  "$APPS_POSITION_X" \
  "$APPS_POSITION_Y" <<'APPLESCRIPT'
on run argv
  set volName to item 1 of argv
  set appName to item 2 of argv
  set bgName to item 3 of argv
  set leftBound to (item 4 of argv) as integer
  set topBound to (item 5 of argv) as integer
  set rightBound to (item 6 of argv) as integer
  set bottomBound to (item 7 of argv) as integer
  set appX to (item 8 of argv) as integer
  set appY to (item 9 of argv) as integer
  set appsX to (item 10 of argv) as integer
  set appsY to (item 11 of argv) as integer

  tell application "Finder"
    tell disk volName
      open
      delay 0.3
      set dmgWindow to container window
      set current view of dmgWindow to icon view
      set toolbar visible of dmgWindow to false
      set statusbar visible of dmgWindow to false
      set bounds of dmgWindow to {leftBound, topBound, rightBound, bottomBound}

      set opts to icon view options of dmgWindow
      set arrangement of opts to not arranged
      set icon size of opts to 128

      if bgName is not "" then
        set background picture of opts to file ".background:" & bgName
      end if

      set position of item appName of dmgWindow to {appX, appY}
      set position of item "Applications" of dmgWindow to {appsX, appsY}

      close
      open
      update without registering applications
      delay 1
    end tell
  end tell
end run
APPLESCRIPT
then
  echo "Warning: Finder layout customization failed; created DMG without custom icon layout." >&2
fi

sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

mkdir -p "$(dirname "$OUTPUT_DMG")"
rm -f "$OUTPUT_DMG"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG"

echo "Created drag-and-drop DMG: $OUTPUT_DMG"
