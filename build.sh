#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="build/Grokus.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp Assets/Grokus.icns "$app/Contents/Resources/Grokus.icns"
swiftc -O -target "$(uname -m)-apple-macosx14.0" Sources/*.swift -o "$app/Contents/MacOS/Grokus"
codesign --force --sign - "$app"
