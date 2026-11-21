#!/bin/zsh
# Builds a distributable Tempus DMG in build/release/.
#
#   scripts/release.sh                 # build, sign, package
#   NOTARY_PROFILE=tempus scripts/release.sh   # …and notarize + staple
#
# With a "Developer ID Application" certificate in the keychain, the app and DMG are
# signed for distribution. With NOTARY_PROFILE set (a profile saved by
# `xcrun notarytool store-credentials`), the DMG is notarized and stapled so it opens
# on any Mac without warnings. Without the certificate, the DMG is built with the
# development signature and macOS will warn people who download it.
#
# Set DMG_LAYOUT=0 to skip arranging the Finder window (it asks Finder via AppleScript).
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

OUT=build/release
ARCHIVE=$OUT/Tempus.xcarchive
STAGE=$OUT/dmg
APP_NAME=Tempus
VOLUME=Tempus

step() { print -P "\n%F{blue}==>%f %B$1%b"; }
warn() { print -P "%F{yellow}warning:%f $1"; }

VERSION=$(xcodebuild -project Tempus.xcodeproj -target Tempus -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
BUILD=$(xcodebuild -project Tempus.xcodeproj -target Tempus -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}')
DMG=$OUT/$APP_NAME-$VERSION.dmg
print -P "%BTempus $VERSION ($BUILD)%b"

rm -rf "$OUT"
mkdir -p "$OUT"

step "Archiving a universal Release build"
xcodebuild archive -project Tempus.xcodeproj -scheme Tempus -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -quiet

DEVELOPER_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
if [[ -n $DEVELOPER_ID ]]; then
  step "Exporting with $DEVELOPER_ID"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions.plist \
    -exportPath "$OUT/export" -quiet
  APP=$OUT/export/$APP_NAME.app
else
  warn "No Developer ID Application certificate found. Using the development signature;"
  warn "people who download this DMG will see a Gatekeeper warning."
  mkdir -p "$OUT/export"
  ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$OUT/export/$APP_NAME.app"
  APP=$OUT/export/$APP_NAME.app
fi

step "Verifying the app"
codesign --verify --deep --strict --verbose=1 "$APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow; then
  print -u2 "error: the app is signed with get-task-allow (a debug signature); notarization would fail"
  exit 1
fi

step "Building the disk image"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
swift scripts/dmg-background.swift "$STAGE/.background/background.tiff"

RW=$OUT/rw.dmg
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ -format UDRW -size 200m "$RW"
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" 2>/dev/null | awk '/Apple_HFS/{print $1}')
MOUNT=/Volumes/$VOLUME
trap 'hdiutil detach -quiet "$DEVICE" 2>/dev/null || true' EXIT

if [[ ${DMG_LAYOUT:-1} != 0 ]]; then
  # Icon positions match the arrow drawn in dmg-background.swift.
  if ! osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
  then
    warn "Could not arrange the DMG window (Finder automation was refused); the DMG still works."
  fi
fi

rm -rf "$MOUNT/.fseventsd"
chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach -quiet "$DEVICE"
trap - EXIT
hdiutil convert -quiet "$RW" -format ULFO -o "$DMG"
rm -f "$RW"
rm -rf "$STAGE"

if [[ -n $DEVELOPER_ID ]]; then
  step "Signing the disk image"
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
fi

if [[ -n ${NOTARY_PROFILE:-} ]]; then
  if [[ -z $DEVELOPER_ID ]]; then
    print -u2 "error: notarization needs a Developer ID Application certificate"
    exit 1
  fi
  step "Notarizing (this usually takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  step "Checking Gatekeeper"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  warn "NOTARY_PROFILE is not set, so the DMG is not notarized."
fi

cp "$DMG" "$OUT/$APP_NAME.dmg"
(cd "$OUT" && shasum -a 256 "$APP_NAME-$VERSION.dmg" > "$APP_NAME-$VERSION.dmg.sha256")

step "Updating the download page"
SIZE=$(ls -l "$DMG" | awk '{printf "%.1f MB", $5 / 1000000}')
SHA=$(awk '{print $1}' "$OUT/$APP_NAME-$VERSION.dmg.sha256")
VERSION=$VERSION SIZE=$SIZE SHA=$SHA perl -0pi -e '
  s{(data-release="version">)[^<]*}{$1$ENV{VERSION}}g;
  s{(data-release="size">)[^<]*}{$1$ENV{SIZE}}g;
  s{(data-release="sha256">)[^<]*}{$1$ENV{SHA}}g;
' docs/index.html
print "docs/index.html → $VERSION, $SIZE"
print "Attach $OUT/$APP_NAME.dmg to a GitHub Release, named exactly Tempus.dmg (the page links to releases/latest/download/Tempus.dmg)."

step "Done"
ls -lh "$DMG"
cat "$OUT/$APP_NAME-$VERSION.dmg.sha256"
