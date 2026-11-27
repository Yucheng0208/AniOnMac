#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p development/.build
xcrun swiftc development/tools/MakeIcon.swift -o development/.build/make-icon
development/.build/make-icon development/.build/AppIcon.iconset development/resources/logo.png
iconutil -c icns development/.build/AppIcon.iconset -o development/resources/AppIcon.icns
