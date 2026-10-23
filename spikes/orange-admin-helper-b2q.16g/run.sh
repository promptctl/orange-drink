#!/bin/bash
# Pause charging through the SMC, drive the events powerd acts on while paused, then resume.
# Run once, in Terminal, at the Mac, plugged in:   sudo ./run.sh
# It prints what to do when it needs a hand (unplug, replug, a Charge Limit toggle) and waits for it.
# Everything it prints lands in output.txt; powerd's and PowerUIAgent's log for the run in powerd.log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] || { echo "run as: sudo ./run.sh" >&2; exit 64; }

# tee ignores ^C, so the exit trap's output still reaches the file and the screen.
exec > >(tee -i "$here/output.txt") 2>&1

smc=$here/build/smc
sudo -u "$SUDO_USER" mkdir -p "$here/build"
sudo -u "$SUDO_USER" swiftc -O "$here/smc.swift" -o "$smc"

policies=/Library/Preferences/com.apple.powerd.charging.plist
step() { printf '\n== %s\n' "$*"; }
now() { date +%H:%M:%S; }
# [LAW:no-silent-failure] A substitution inside echo's arguments drops its exit status, so each one is
# assigned on its own line first; and the conditions below run where errexit is off, so they exit
# themselves when the observer fails rather than reading its silence as "not yet".
observe() { local o; o=$("$smc" observe) || exit 1; echo "$(now) $o"; }
# One field of an observe line, e.g. `field IsCharging "$line"`.
field() { sed -E "s/.*[ ]$1=([^ ]+).*/\1/" <<<" $2"; }
# The Charge Limit policy powerd keeps, on one line: the archived ChargeCtrlPolicy's fields. powerd
# rewrites this file on its own (isEndOfCharge flips at the limit), so it is recorded, never waited on.
# [LAW:dataflow-not-control-flow] No policies file, no policies key, or no policy in it, is a state of
# its own; only a file plutil cannot read fails the caller.
policy() {
  local outer
  [ -e "$policies" ] || { echo "no policies file"; return; }
  outer=$(plutil -p "$policies") || return 1
  case $outer in
    *'"policies" =>'*)
      plutil -extract policies raw -o - "$policies" | base64 -d | plutil -p - |
        awk '/"(soclimit|terminated|drain|isEndOfCharge|noChargeToFull)"|"[A-Za-z]*ChargeLimit"/ { $1 = $1; printf "%s  ", $0; n++ }
             END { if (!n) printf "no charge policy"; print "" }' ;;
    *) echo "no policies key" ;;
  esac
}
# A dead log stream would make an empty powerd.log read as "powerd said nothing".
logging() { kill -0 "$log_pid" || { echo "log stream stopped: powerd.log is incomplete"; exit 1; }; }

# [LAW:no-ambient-temporal-coupling] Every wait is a named condition polled every 5 s against a deadline;
# the run never sleeps on the hope that something has happened. A miss returns 1 and the caller says
# what the miss means. The one event the Mac cannot see, a Settings toggle, is owned by the person:
# the run waits for their Return.
await() {
  local what=$1 deadline=$(( SECONDS + $2 )); shift 2
  until "$@"; do
    (( SECONDS < deadline )) || { echo "$(now) deadline: $what"; return 1; }
    sleep 5
  done
  echo "$(now) reached: $what"
}

paused() { local l; l=$(observe) || exit 1; echo "$l"; [ "$(field IsCharging "$l")" = 0 ] && [ "$(field ChargingCurrent "$l")" = 0 ]; }
charging() { local l; l=$(observe) || exit 1; echo "$l"; [ "$(field IsCharging "$l")" = 1 ] && [ "$(field ChargingCurrent "$l")" -gt 0 ]; }
external() { local l; l=$(observe) || exit 1; echo "$l"; [ "$(field ExternalConnected "$l")" = "$1" ]; }
woke_since() { [ "$(sysctl -n kern.waketime)" != "$1" ]; }
# A Settings change, done by the person and confirmed with Return; then the policy it left.
toggled() { local p; read -r -p "$1, then press Return: "; p=$(policy); echo "$(now) $1: policy $p"; }

# What powerd did after an event: the pause key and the outside view, every 5 s for 30 s.
settle() {
  local end=$(( SECONDS + 30 )) held line
  while (( SECONDS < end )); do
    held=$("$smc" read "$key")
    line=$(observe)
    echo "$line $key=$held"
    sleep 5
  done
}

step "0. machine, keys, baseline"
sw_vers; sysctl -n machdep.cpu.brand_string
# As the user, so a key the SMC guards from an unprivileged reader is listed with its refusal.
sudo -u "$SUDO_USER" "$smc" list | tee "$here/build/list.txt"
start_policy=$(policy)
echo "Charge Limit policy: $start_policy"
# A pause can only be told from the native limit if the Mac is charging when the run starts.
charging || { echo "not charging at the start (on battery, or held at the Charge Limit): nothing to pause"; exit 1; }

# The inhibit key prior art ranks first; the list above is this SMC's answer for whether it exists.
key=CHTE pause=01000000
grep "^$key " "$here/build/list.txt" || { echo "$key is not on this SMC: nothing to pause with"; exit 1; }
# [LAW:one-source-of-truth] The restore value is the key as found, read before any write is attempted.
baseline=$("$smc" read "$key")
echo "pause key $key: baseline $baseline, pause value $pause"
echo "manual restore if this run dies uncaught: sudo $smc write $key $baseline"

restore() {
  local status=$?
  # Every step runs and reports its own failure; and the write comes first, because after a closed
  # Terminal nothing printed before it would survive. A second ^C must not kill the write: ignored
  # signals stay ignored in the children.
  trap '' INT TERM HUP
  set +e
  "$smc" write "$key" "$baseline" || echo "RESTORE FAILED: run  sudo $smc write $key $baseline"
  echo "$(now) exit $status: $key restored to"
  "$smc" read "$key"
  # The run can stop between the two toggles, and only the person can turn the limit back on.
  echo "Charge Limit at the start: $start_policy"
  echo "Charge Limit now:          $(policy)"
  echo "If Charge Limit is off, turn it back on: System Settings > Battery > Charging"
  kill "$log_pid" || echo "log stream had already stopped"
  exit "$status"
}

log stream --style compact --predicate 'process == "powerd" OR process == "PowerUIAgent"' > "$here/powerd.log" &
log_pid=$!

trap restore EXIT

step "1. the same write without root"
if refusal=$(sudo -u "$SUDO_USER" "$smc" write "$key" "$pause" 2>&1); then
  echo "UNEXPECTED: the SMC accepted an unprivileged write; stopping, since the root write can no longer be told apart"
  exit 1
fi
echo "$refusal"
# Only a privilege refusal shows that root is what the write needs; any other failure shows nothing.
[[ $refusal == *kIOReturnNotPrivileged* ]] || { echo "the unprivileged write failed, but not for privilege; stopping"; exit 1; }
held=$("$smc" read "$key")
echo "$key after the unprivileged attempt: $held (baseline $baseline)"
[ "$held" = "$baseline" ] || { echo "UNEXPECTED: the refused write changed $key; stopping, since the root write can no longer be told apart"; exit 1; }

logging
step "2. pause: write $key $pause as root; the writer exits before anything is observed"
"$smc" write "$key" "$pause"
# Without a pause, every event below would record ordinary charging; the miss is the finding.
await "charging stopped" 60 paused || { echo "NOT PAUSED within 60 s: $key $pause does not pause charging here"; exit 1; }

step "3a. unplug the charger now, and leave it out until told"
if await "unplugged" 180 external 0; then
  settle
  step "3a. plug the charger back in"
  # Every step after this one needs the charger in.
  await "replugged" 180 external 1 || { echo "event not driven: replug; the rest of the run needs the charger"; exit 1; }
  settle
else
  echo "event not driven: unplug"
fi

step "3b. sleep, woken by the machine 40 s later"
before=$(sysctl -n kern.waketime)
pmset relative wake 40
pmset sleepnow
if await "woke" 180 woke_since "$before"; then settle; else echo "event not driven: sleep and wake"; fi

step "3c. Charge Limit off and on again, in System Settings > Battery > Charging"
toggled "Charge Limit turned off"
settle
toggled "Charge Limit turned back on"
settle

step "4. resume: write the baseline back"
# What the key holds now says whether anything but this run wrote it while paused.
held=$("$smc" read "$key")
echo "$key holds $held before resume (wrote $pause)"
"$smc" write "$key" "$baseline"
await "charging resumed" 60 charging || echo "NOT RESUMED within 60 s"

logging
step "powerd and PowerUIAgent on charging, for the whole run"
grep -iE 'charg|inhibit|CHNC|limit' "$here/powerd.log" || echo "no charging lines in powerd.log"
