#!/bin/bash
# Builds a minimal MenuBarExtra app around the project's own HotKey and panel keyboard sources, opens its panel with a
# real ⌃⌥J key press, then types i, i, d, d, x into it and prints the sections' state after each. The letters are
# typed only while the panel is the app's key window. Output: output.txt.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -parse-as-library -o build/s4n main.swift ../../Sources/OrangeDrink/HotKey/*.swift \
  ../../Sources/OrangeDrink/Panel/PanelKeyboard.swift ../../Sources/OrangeDrink/Panel/PanelSections.swift
build/s4n > output.txt 2>&1 &
pid=$!
for _ in $(seq 1 20); do sleep 1; kill -0 $pid 2>/dev/null || break; done
kill $pid 2>/dev/null || true
cat output.txt
