#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build Release app, create drag-and-drop DMG, and verify version consistency.

Usage:
  scripts/build_release_dmg.sh --version 1.3.1

Optional:
  --project /path/to/DownloadsOrganizer.xcodeproj
  --scheme DownloadsOrganizer
  --derived-data /tmp/FolderTidyRelease
  --output /path/to/release/Folder_Tidy_v1.3.1.dmg
  --volume-name "Folder Tidy"
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
PROJECT_PATH="$REPO_ROOT/DownloadsOrganizer.xcodeproj"
SCHEME="DownloadsOrganizer"
DERIVED_DATA="/tmp/FolderTidyRelease"
VOLUME_NAME="Folder Tidy"
OUTPUT_DMG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT_PATH="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
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

if [[ -z "$VERSION" ]]; then
  echo "Error: --version is required." >&2
  usage
  exit 1
fi

if [[ -z "$OUTPUT_DMG" ]]; then
  OUTPUT_DMG="$REPO_ROOT/release/Folder_Tidy_v${VERSION}.dmg"
fi

echo "Building Release app..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release/Folder Tidy.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: built app not found: $APP_PATH" >&2
  exit 1
fi

echo "Verifying app bundle version..."
"$SCRIPT_DIR/verify_app_version.sh" --app "$APP_PATH" --expected-version "$VERSION"

echo "Creating DMG..."
"$SCRIPT_DIR/create_dragdrop_dmg.sh" \
  --app "$APP_PATH" \
  --output "$OUTPUT_DMG" \
  --volume-name "$VOLUME_NAME"

echo "Verifying DMG bundle version..."
"$SCRIPT_DIR/verify_dmg_version.sh" \
  --dmg "$OUTPUT_DMG" \
  --expected-version "$VERSION" \
  --app-name "Folder Tidy.app"

echo "Release artifact verified: $OUTPUT_DMG"
