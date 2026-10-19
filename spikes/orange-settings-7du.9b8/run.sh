#!/bin/bash
# Builds Spike.app (a String Catalog with en and fr compiled into its Resources, like the real app's
# bundle) and runs it on the real Mac and with the Mac forced to fr; the output lands in output.txt.
set -euo pipefail
cd "$(dirname "$0")"
out=build/Spike.app
rm -rf build && mkdir -p $out/Contents/MacOS $out/Contents/Resources
xcrun xcstringstool compile --output-directory $out/Contents/Resources Localizable.xcstrings
cat > $out/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleIdentifier</key><string>spike.lang</string><key>CFBundleName</key><string>Spike</string>
<key>CFBundleExecutable</key><string>spike</string><key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
</dict></plist>
PLIST
swiftc -parse-as-library -o $out/Contents/MacOS/spike spike.swift
{
  ls $out/Contents/Resources
  echo; echo "################ the real Mac, no argument"
  $out/Contents/MacOS/spike
  echo; echo "################ the Mac forced to fr at launch (command-line -AppleLanguages)"
  $out/Contents/MacOS/spike -AppleLanguages "(fr)" -AppleLocale "fr_FR"
} > output.txt 2>&1   # set -e: a crashing run stops here, not after a half-written record
cat output.txt
