#!/bin/bash
# Samples the same 20-second window three ways at once and prints each one's top five:
#   A. rusage.swift: proc_pid_rusage ri_energy_nj deltas, grouped under the responsible process's .app
#   B. top -stats power (its Energy-Impact-style column)
#   C. Activity Monitor's Energy tab read through the accessibility tree (needs Accessibility trust and
#      Activity Monitor open; its table is read once, at the end of the window)
# Then the CPU cost of each sampler. Output: output.txt.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -o build/rusage rusage.swift
open -a "Activity Monitor"; sleep 2
build/rusage 10 3 > build/rusage.out &
/usr/bin/time -l top -l 3 -s 10 -stats pid,command,power -o power -n 15 > build/top.out 2> build/top.time &
sleep 19
osascript activity-monitor.applescript > build/am.out
wait
echo "=== A. proc_pid_rusage energy, top five apps"
sed -n '/per app/,$p' build/rusage.out | sed -n '2,7p'
grep -E "responsibility|unreadable|sampler CPU" build/rusage.out
echo "=== B. top power column, last sample, top ten processes"
awk '/^PID/{n++} n==3' build/top.out | head -11
echo "=== C. Activity Monitor Energy tab: app | energy impact | 12 hr power, sorted by energy impact, top eight"
sort -t'|' -k2 -rn build/am.out | head -8
echo "=== top's own cost for 3 samples over 20 s"
grep -E "real|user|sys" build/top.time | head -3
echo "=== A continuous at 5 s for 60 s (13 snapshots)"
build/rusage 5 13 | grep -E "window|sampler CPU"
