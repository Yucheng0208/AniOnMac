#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out='development/.build/release'
mkdir -p "$out"
codesign --verify --deep --strict AniOnMac.app
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AniOnMac.app/Contents/Info.plist)

# ZIP
rm -f "$out/AniOnMac-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent AniOnMac.app "$out/AniOnMac-macOS-universal.zip"
echo "Created $out/AniOnMac-macOS-universal.zip"

# DMG: the app plus an Applications shortcut to drag it onto, with the app icon as the volume icon
stage="$out/dmg-stage"
rm -rf "$stage" "$out/AniOnMac-macOS-universal.dmg"
mkdir -p "$stage"
ditto AniOnMac.app "$stage/AniOnMac.app"
ln -s /Applications "$stage/Applications"
cp development/resources/AppIcon.icns "$stage/.VolumeIcon.icns"
hdiutil create -quiet -fs HFS+ -volname "AniOnMac $version" -srcfolder "$stage" -format UDRW -ov "$out/dmg-rw.dmg"
mount=$(mktemp -d)
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$mount" "$out/dmg-rw.dmg"
SetFile -a C "$mount" 2>/dev/null || xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$mount"
hdiutil detach -quiet "$mount"
hdiutil convert -quiet "$out/dmg-rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out/AniOnMac-macOS-universal.dmg"
rm -rf "$stage" "$out/dmg-rw.dmg"
hdiutil verify -quiet "$out/AniOnMac-macOS-universal.dmg"
echo "Created $out/AniOnMac-macOS-universal.dmg"
echo 'Local ad-hoc signature only; Developer ID signing and notarization are still required for a trusted public release'
