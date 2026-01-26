#!/bin/bash -ex

create-dmg \
  --volname "Open Note Taker" \
  --volicon "images/dmg-icon.png" \
  --background "images/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "OpenNoteTaker.app" 175 190 \
  --hide-extension "OpenNoteTaker.app" \
  --app-drop-link 425 190 \
  "OpenNoteTaker.dmg" \
  "/Users/petewarden/Downloads/OpenNoteTaker.app"