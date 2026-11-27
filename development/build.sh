#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work='development/.build'
app='AniOnMac.app'
mkdir -p "$work" "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun clang -arch "$arch" -mmacosx-version-min=14.0 -fobjc-arc -Wall -Wextra -framework AppKit development/native/cursorctl.m -o "$work/cursorctl-$arch"
  xcrun clang -arch "$arch" -mmacosx-version-min=14.0 -fobjc-arc -c development/native/CursorRefresh.m -o "$work/refresh-$arch.o"
  xcrun swiftc -swift-version 5 -target "$arch-apple-macosx14.0" -module-cache-path "$work/swift-cache" development/native/ANIConverter.swift -o "$work/anicore-$arch"
  xcrun swiftc -parse-as-library -swift-version 5 -target "$arch-apple-macosx14.0" -module-cache-path "$work/swift-cache" development/app/Studio.swift development/app/Views.swift "$work/refresh-$arch.o" -o "$work/app-$arch"
done
lipo -create "$work/app-arm64" "$work/app-x86_64" -output "$app/Contents/MacOS/AniOnMac"
for tool in anicore cursorctl; do
  lipo -create "$work/$tool-arm64" "$work/$tool-x86_64" -output "$app/Contents/Resources/$tool"
  codesign --force --sign - "$app/Contents/Resources/$tool"
done
cp development/resources/*.json "$app/Contents/Resources/"
# One .lproj per bundled language so AppKit localizes the system menus
# (Edit, View, Window, Help…) instead of falling back to English.
for json in development/resources/*.json; do
  lang=$(basename "$json" .json)
  mkdir -p "$app/Contents/Resources/$lang.lproj"
  printf '"CFBundleDisplayName" = "AniOnMac";\n"CFBundleName" = "AniOnMac";\n' > "$app/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
cp development/resources/AppIcon.icns development/resources/logo.png "$app/Contents/Resources/"
commit=$(git rev-parse HEAD 2>/dev/null || true)
commit_date=$(git log -1 --format=%cI 2>/dev/null || true)
export commit commit_date
python3 - <<'PY'
import plistlib, os
from pathlib import Path
p=Path('AniOnMac.app/Contents/Info.plist')
langs=sorted(x.stem for x in Path('development/resources').glob('*.json'))
p.write_bytes(plistlib.dumps(dict(CFBundleDevelopmentRegion='en',CFBundleLocalizations=langs,CFBundleAllowMixedLocalizations=True,CFBundleExecutable='AniOnMac',CFBundleIdentifier='io.anionmac.app',CFBundleName='AniOnMac',CFBundleDisplayName='AniOnMac',CFBundleIconFile='AppIcon',CFBundlePackageType='APPL',CFBundleShortVersionString='0.3.0',CFBundleVersion='6',NSHumanReadableCopyright='© lx3211 · https://github.com/lx3211/AniOnMac',AniOnMacCommit=os.environ.get('commit',''),AniOnMacCommitDate=os.environ.get('commit_date',''),LSMinimumSystemVersion='14.0',NSHighResolutionCapable=True)))
PY
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app (Universal: arm64 + x86_64)"
