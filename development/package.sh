#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p development/.build/release
codesign --verify --deep --strict AniOnMac.app
ditto -c -k --sequesterRsrc --keepParent AniOnMac.app development/.build/release/AniOnMac-macOS-universal.zip
echo 'Created development/.build/release/AniOnMac-macOS-universal.zip'
echo 'Local ad-hoc signature only; Developer ID signing and notarization are still required for a trusted public release'
