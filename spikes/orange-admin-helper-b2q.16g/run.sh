#!/bin/bash
# Pause charging through the SMC, drive the events powerd acts on while paused, then resume.
# Run once, in Terminal, at the Mac, plugged in:   sudo ./run.sh
# It prints what to do when it needs a hand (unplug, replug, a Charge Limit toggle) and waits for it.
# Everything it prints lands in output.txt; powerd's and PowerUIAgent's log for the run in powerd.log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] || { echo "run as: sudo ./run.sh" >&2; exit 64; }

exec > >(tee "$here/output.txt") 2>&1

smc=$here/build/smc
sudo -u "$SUDO_USER" mkdir -p "$here/build"
sudo -u "$SUDO_USER" swiftc -O "$here/smc.swift" -o "$smc"

policies=/Library/Preferences/com.apple.powerd.charging.plist
step() { printf '\n== %s\n' "$*"; }
now() { date +%H:%M:%S; }
observe() { echo "$(now) $("$smc" observe)"; }
# One field of an observe line, e.g. `field IsCharging "$line"`.
field() { sed -E "s/.*[ ]$1=([^ ]+).*/\1/" <<<" $2"; }
policy_digest() { plutil -extract policies raw -o - "$policies" | shasum | cut -c1-12; }

# [LAW:no-ambient-temporal-coupling] Every wait is a named condition polled every 5 s against a deadline;
# the run never sleeps on the hope that something has happened. A miss returns 1 and the caller says
# what the miss means.
await() {
  local what=$1 deadline=$(( SECONDS + $2 )); shift 2
  until "$@"; do
    (( SECONDS < deadline )) || { echo "$(now) deadline: $what"; return 1; }
    sleep 5
  done
  echo "$(now) reached: $what"
}

paused() { local l; l=$(observe); echo "$l"; [ "$(field IsCharging "$l")" = 0 ] && [ "$(field ChargingCurrent "$l")" = 0 ]; }
charging() { local l; l=$(observe); echo "$l"; [ "$(field IsCharging "$l")" = 1 ] && [ "$(field ChargingCurrent "$l")" -gt 0 ]; }
external() { local l; l=$(observe); echo "$l"; [ "$(field ExternalConnected "$l")" = "$1" ]; }
woke_since() { [ "$(sysctl -n kern.waketime)" != "$1" ]; }
policy_changed_from() { [ "$(policy_digest)" != "$1" ]; }

# What powerd did after an event: the pause key and the outside view, every 5 s for 30 s.
settle() {
  local end=$(( SECONDS + 30 ))
  while (( SECONDS < end )); do
    echo "$(now) $key=$("$smc" read "$key") $("$smc" observe)"
    sleep 5
  done
}

step "0. machine, keys, baseline"
sw_vers; sysctl -n machdep.cpu.brand_string
"$smc" list | tee "$here/build/list.txt"
echo "Charge Limit policies digest: $(policy_digest)"
observe

# [LAW:dataflow-not-control-flow] The candidates are data, in the order prior art ranks them: an inhibit
# key first, the adapter cut (which discharges rather than pauses) last. The first one this SMC
# answers for is the key the run uses.
candidate=$(awk 'NR==FNR { readable[$1] = ($2 != "refused:"); next }
                 readable[$1] { print; exit }' "$here/build/list.txt" - <<'EOF'
CHTE 01000000 inhibit
CH0B 02 inhibit
CH0C 02 inhibit
CHIE 08 adapter-cut
EOF
)
[ -n "$candidate" ] || { echo "no candidate pause key is readable on this SMC"; exit 1; }
read -r key pause label <<<"$candidate"
# [LAW:one-source-of-truth] The restore value is the key as found, read before any write is attempted.
baseline=$("$smc" read "$key")
echo "pause key $key ($label): baseline $baseline, pause value $pause"
echo "manual restore if this run dies uncaught: sudo $smc write $key $baseline"

restore() {
  local status=$?
  echo "$(now) exit: restoring $key to $baseline"
  "$smc" write "$key" "$baseline" || echo "RESTORE FAILED: run  sudo $smc write $key $baseline"
  echo "$(now) $key=$("$smc" read "$key")"
  kill "$log_pid"
  exit "$status"
}

log stream --style compact --predicate 'process == "powerd" OR process == "PowerUIAgent"' > "$here/powerd.log" &
log_pid=$!

trap restore EXIT

step "1. the same write without root"
if sudo -u "$SUDO_USER" "$smc" write "$key" "$pause"; then
  echo "UNEXPECTED: the SMC accepted an unprivileged write"
fi
echo "$key after the unprivileged attempt: $("$smc" read "$key") (baseline $baseline)"

step "2. pause: write $key $pause as root; the writer exits before anything is observed"
"$smc" write "$key" "$pause"
await "charging stopped" 60 paused || echo "NOT PAUSED within 60 s"

step "3a. unplug the charger now, then plug it back in"
if await "unplugged" 180 external 0; then
  settle
  if await "replugged" 180 external 1; then settle; else echo "event not driven: replug"; fi
else
  echo "event not driven: unplug"
fi

step "3b. sleep, woken by the machine 40 s later"
before=$(sysctl -n kern.waketime)
pmset relative wake 40
pmset sleepnow
if await "woke" 180 woke_since "$before"; then settle; else echo "event not driven: sleep and wake"; fi

step "3c. System Settings > Battery > Charging > Charge Limit: turn it off"
digest=$(policy_digest)
if await "Charge Limit policy changed" 180 policy_changed_from "$digest"; then
  echo "policies digest now $(policy_digest)"
  settle
  step "3c. now turn Charge Limit back on"
  digest=$(policy_digest)
  if await "Charge Limit policy changed" 180 policy_changed_from "$digest"; then
    echo "policies digest now $(policy_digest)"
    settle
  else
    echo "event not driven: Charge Limit on"
  fi
else
  echo "event not driven: Charge Limit off"
fi

step "4. resume: write the baseline back"
"$smc" write "$key" "$baseline"
await "charging resumed" 60 charging || echo "NOT RESUMED within 60 s"

step "powerd and PowerUIAgent on charging, for the whole run"
grep -iE 'charg|inhibit|CHNC|limit' "$here/powerd.log" || echo "no charging lines in powerd.log"
