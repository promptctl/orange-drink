#!/bin/bash
# Builds Spike.app (a String Catalog with en and fr compiled into its Resources, like the real app's
# bundle) and runs it twice: once with the Mac's language en, once fr, to show Match System each way.
set -euo pipefail
cd "$(dirname "$0")"
out=build/Spike.app
rm -rf build && mkdir -p $out/Contents/MacOS $out/Contents/Resources
xcrun xcstringstool compile --output-directory $out/Contents/Resources Localizable.xcstrings
cat > $out/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>spike.lang</string><key>CFBundleName</key><string>Spike</string>
<key>CFBundleExecutable</key><string>spike</string><key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
</dict></plist>
PLIST
swiftc -parse-as-library -o $out/Contents/MacOS/spike spike.swift 2>&1 | grep -v "^$" || true
ls $out/Contents/Resources
for mac in en fr; do
  echo; echo "################ the Mac is set to: $mac"
  $out/Contents/MacOS/spike -AppleLanguages "($mac)" -AppleLocale "${mac}_US"
done
