#!/bin/bash -ex

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_NAME="Moonshine Note Taker"

set -o allexport
source "$SCRIPT_DIR/../.env"
set +o allexport

# Build the app in Release mode and copy the result to ~/Downloads/
ARCHIVE_PATH="$(pwd)/build/MoonshineNoteTaker.xcarchive"
xcodebuild \
	-project MoonshineNoteTaker.xcodeproj \
	-scheme "MoonshineNoteTaker" \
	-configuration Release \
	CONFIGURATION_BUILD_DIR="$(pwd)/build" \
	-derivedDataPath ./build \
	-archivePath "$ARCHIVE_PATH" \
	archive

EXPORT_PATH="$(pwd)/build/export"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist ExportOptions.plist

APP_PATH="$EXPORT_PATH/$APP_NAME.app"

TMP_DIR=$(mktemp -d)

cp -R "${APP_PATH}" "${TMP_DIR}/${APP_NAME}.app"

rm -rf MoonshineNoteTaker*.dmg

DATE_SUFFIX=$(date +_%Y_%m_%d)

DMG_NAME="MoonshineNoteTaker$DATE_SUFFIX.dmg"

create-dmg \
	--volname "$APP_NAME" \
	--volicon "images/dmg-icon.png" \
	--background "images/dmg-background.png" \
	--window-pos 200 120 \
	--window-size 600 400 \
	--icon-size 100 \
	--icon "$APP_NAME.app" 175 190 \
	--hide-extension "$APP_NAME.app" \
	--app-drop-link 425 190 \
	"$DMG_NAME" \
	"$TMP_DIR/$APP_NAME.app"

codesign --force --sign "$CERT_ID" "$DMG_NAME"
xcrun notarytool submit "$DMG_NAME" \
    --apple-id $APPLE_ID \
    --team-id $DEV_TEAM_ID \
    --password $APP_SPECIFIC_PASSWORD \
    --wait
xcrun stapler staple "$DMG_NAME"

gsutil -h "Content-Type:application/x-apple-diskimage" -h "Content-Encoding:" \
  cp "$DMG_NAME" "gs://download.moonshine.ai/apps/note-taker/$DMG_NAME"

rm -rf "$TMP_DIR"
