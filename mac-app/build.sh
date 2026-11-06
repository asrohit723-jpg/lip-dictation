#!/bin/zsh
# Builds "Lip Dictation.app".
#   VERSION       version to stamp (default 0.0.0, a local build any release replaces)
#   SIGN_IDENTITY codesign identity (default: ad hoc). Releases are signed on GitHub
#                 with the app's own certificate; see .github/workflows/release.yml.
#   KEYCHAIN      keychain holding that identity (optional)
#   INSTALL       1 copies the app into ~/Applications (default 0)
#
# An ad hoc build is "Lip Dictation Dev" (com.rohit.lipdictation.dev). macOS keeps the Camera
# and Accessibility permissions per app identity, so a local build sharing the real app's
# identifier, with a different signature, would make macOS forget them and ask again every
# time you switched between the two.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-0.0.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
INSTALL="${INSTALL:-0}"
NAME="Lip Dictation"
BUNDLE_ID=com.rohit.lipdictation
if [ "$SIGN_IDENTITY" = "-" ]; then
  NAME="Lip Dictation Dev"
  BUNDLE_ID=com.rohit.lipdictation.dev
fi

APP="build/$NAME.app"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp .build/release/LipDictation "$APP/Contents/MacOS/LipDictation"

# The engine's Python source, run by the app from inside the bundle.
ENGINE="$APP/Contents/Resources/engine"
mkdir -p "$ENGINE"
rsync -a --exclude __pycache__ --exclude '*.pyc' ../lipdictation ../espnet "$ENGINE/"
cp ../requirements-engine.txt "$ENGINE/requirements.txt"
cp ../NOTICE "$APP/Contents/Resources/NOTICE"

# uv fetches Python and the engine's libraries on first launch (pinned and checked)
UV="$(scripts/fetch-uv.sh)"
cp "$UV" "$APP/Contents/Helpers/uv"

# Icon
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>__NAME__</string>
  <key>CFBundleDisplayName</key><string>__NAME__</string>
  <key>CFBundleIdentifier</key><string>__BUNDLE_ID__</string>
  <key>CFBundleExecutable</key><string>LipDictation</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>__VERSION__</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key>
  <string>Lip Dictation reads your lips while you hold the dictation key. Video is processed on this Mac and never saved or sent anywhere.</string>
</dict>
</plist>
PLIST
sed -i '' -e "s/__VERSION__/$VERSION/g" -e "s/__NAME__/$NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" "$APP/Contents/Info.plist"

KEYCHAIN_ARGS=()
[ -n "${KEYCHAIN:-}" ] && KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
codesign --force --sign "$SIGN_IDENTITY" "${KEYCHAIN_ARGS[@]}" --identifier "$BUNDLE_ID.uv" "$APP/Contents/Helpers/uv"
codesign --force --sign "$SIGN_IDENTITY" "${KEYCHAIN_ARGS[@]}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built: $APP ($VERSION)"

if [ "$INSTALL" = 1 ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"$NAME.app"
  cp -R "$APP" ~/Applications/
  echo "Installed: ~/Applications/$NAME.app"
fi
