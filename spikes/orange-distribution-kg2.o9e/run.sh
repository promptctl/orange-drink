#!/bin/bash
# Runs proof.sh in a throwaway VM of each Tart image named, and appends what a finished run prints to output.txt.
set -euo pipefail
cd "$(dirname "$0")"
scratch=$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/o9e.XXXXXX")")
vm=orange-o9e-$$
finish() { status=$?; tart stop "$vm" >&2 || true; tart delete "$vm" >&2 || true; rm -rf "$scratch"; exit "$status"; }
trap finish EXIT

swiftc -O -target arm64-apple-macos14 -o "$scratch/banners" banners.swift
swiftc -O -target arm64-apple-macos14 -o "$scratch/fake-battery" fake-battery.swift
cp proof.sh "$scratch"

for image; do
  tart clone "$image" "$vm"
  tart run --no-graphics --dir="run:$scratch:ro" "$vm" >&2 &
  for _ in $(seq 1 180); do tart exec "$vm" true >/dev/null 2>&1 && break; sleep 1; done
  tart exec "$vm" sh '/Volumes/My Shared Files/run/proof.sh' 2>&1 | tee "$scratch/proof.out"
  cat "$scratch/proof.out" >> output.txt
  tart stop "$vm" >&2
  wait
  tart delete "$vm" >&2
done
