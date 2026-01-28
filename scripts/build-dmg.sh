#!/bin/bash -ex

# Build the app in Release mode and copy the result to ~/Downloads/
xcodebuild \
  -project MoonshineNoteTaker.xcodeproj \
  -scheme "MoonshineNoteTaker" \
  -configuration Release \
  CONFIGURATION_BUILD_DIR="$(pwd)/build" \
  -derivedDataPath ./build \
  build

# Find the built .app and copy it to ~/Downloads/
APP_PATH="build/Moonshine Note Taker.app"
if [ -d "$APP_PATH" ]; then
	cp -R "$APP_PATH" ~/Downloads/
else
	echo "Moonshine Note Taker.app not found in build/Release."
	exit 1
fi

rm -rf MoonshineNoteTaker.dmg

create-dmg \
	--volname "Moonshine Note Taker" \
	--volicon "images/dmg-icon.png" \
	--background "images/dmg-background.png" \
	--window-pos 200 120 \
	--window-size 600 400 \
	--icon-size 100 \
	--icon "Moonshine Note Taker.app" 175 190 \
	--hide-extension "Moonshine Note Taker.app" \
	--app-drop-link 425 190 \
	"MoonshineNoteTaker.dmg" \
	"/Users/petewarden/Downloads/Moonshine Note Taker.app"
