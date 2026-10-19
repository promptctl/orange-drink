#!/bin/bash
# Builds a minimal MenuBarExtra app around the project's own HotKey sources, posts a real ⌃⌥J key press
# to the system twice, and prints whether the panel is open before and after each. Output: output.txt.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -parse-as-library -o build/hk main.swift ../../Sources/OrangeDrink/HotKey/*.swift
build/hk > output.txt 2>&1 &
pid=$!
sleep 6
kill $pid 2>/dev/null || true
cat output.txt
