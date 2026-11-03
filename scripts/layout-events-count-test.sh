#!/bin/bash
# [LAW:behavior-not-structure] scripts/layout-events-count.swift seen from outside: --replay feeds it recorded events and
# the test asserts the figures it prints, so the buckets and clusters that decide a ticket are held with no Accessibility
# trust and no NotificationCenter.
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/layout-events-count.swift
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -o "$scratch/count" "$script"

failures=0
expect() { # <what> <seconds> <events> <expected output lines...>: one assertion, reported either way
  local what=$1 seconds=$2 events=$3; shift 3
  local want got
  want=$(printf 'layout-events-count: %s\n' "$@")
  got=$(printf '%b' "$events" | "$scratch/count" --replay "$seconds" 2>&1) || true
  if [ "$got" = "$want" ]; then echo "ok: $what"; else echo "FAIL: $what"; echo "  want:"; echo "$want" | sed 's/^/    /'; echo "  got:"; echo "$got" | sed 's/^/    /'; failures=$((failures + 1)); fi
}

expect "a quiet run is zero events and zero clusters in every minute" 120 "" \
  "0 events in 120 s, 0.00 a minute" "0 clusters, 0.00 a minute" "per minute [0, 0]" "by source []"

expect "one banner's four events at an instant are one cluster, and the next minute's two are another" 180 \
  '0.0 AXGroup/AXNotificationCenterBanner\n0.1 AXGroup/AXNotificationCenterBanner\n0.2 AXScrollArea/-\n0.3 AXScrollArea/-\n65 AXGroup/AXNotificationCenterBanner\n65.5 AXGroup/AXNotificationCenterBanner\n' \
  "6 events in 180 s, 2.00 a minute" "2 clusters, 0.67 a minute" "per minute [4, 2, 0]" \
  "by source [\"AXGroup/AXNotificationCenterBanner 4\", \"AXScrollArea/- 2\"]"

expect "a steady stream 0.9 s apart is a cluster per two events, not one burst" 60 \
  '0 A\n0.9 A\n1.8 A\n2.7 A\n3.6 A\n' \
  "5 events in 60 s, 5.00 a minute" "3 clusters, 3.00 a minute" "per minute [5]" "by source [\"A 5\"]"

expect "an event at a minute's start is that minute's, and one at the run's end is the last minute's" 120 \
  '60 A\n120 A\n' \
  "2 events in 120 s, 1.00 a minute" "2 clusters, 1.00 a minute" "per minute [0, 2]" "by source [\"A 2\"]"

want="usage: layout-events-count.swift [seconds] | --replay seconds < events"
for bad in "inf" "0" "-5" "1e400" "abc"; do
  got=$("$scratch/count" "$bad" 2>&1) || true
  if [ "$got" = "layout-events-count: $want" ]; then echo "ok: seconds $bad is refused with the usage"; else echo "FAIL: seconds $bad: $got"; failures=$((failures + 1)); fi
done

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
