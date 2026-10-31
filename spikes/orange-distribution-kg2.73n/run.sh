#!/bin/bash
# Each variant as an app of its own bundle id, so each meets the prompt with a TCC entry of its own, in one fresh VM.
#   spikes/orange-distribution-kg2.73n/run.sh <xctestrun of the OrangeDrinkUITests scheme> [variant...]
set -euo pipefail
xctestrun=$(realpath "$1"); shift
variants=("$@"); [ ${#variants[@]} -gt 0 ] || variants=(main pool thread central)
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../.."
. scripts/vm-check-lib
swiftc -O -swift-version 5 "$here/spike.swift" -o "$scratch/spike" -framework IOBluetooth -framework CoreBluetooth -framework AppKit
swiftc -O -swift-version 5 -module-name rebuilt "$here/spike.swift" -o "$scratch/rebuilt" -framework IOBluetooth -framework CoreBluetooth -framework AppKit
for v in "${variants[@]}"; do
  a="$scratch/BTSpike-$v.app"; mkdir -p "$a/Contents/MacOS"; cp "$scratch/spike" "$a/Contents/MacOS/spike"
  plutil -create xml1 "$a/Contents/Info.plist"
  for kv in CFBundleIdentifier=com.orangedrink.spike.$v CFBundleExecutable=spike CFBundleName=BTSpike$v NSBluetoothAlwaysUsageDescription=spike; do
    plutil -insert "${kv%%=*}" -string "${kv#*=}" "$a/Contents/Info.plist"
  done
  plutil -insert LSUIElement -bool true "$a/Contents/Info.plist"
  codesign -s - "$a"
  ditto -c -k --keepParent "$a" "$scratch/BTSpike-$v.zip"
done
vm_start "$xctestrun"
guest sh -c "mkdir -p /Users/admin/Applications"
for v in "${variants[@]}"; do
  guest sh -c "cd /Users/admin/Applications && ditto -x -k '$shared/BTSpike-$v.zip' ."
  echo "=== $v, prompt unanswered"
  guest open "/Users/admin/Applications/BTSpike-$v.app"
  sleep 10
  guest cat "/tmp/spike-$v.log"
  echo "=== $v, answering"
  xctest "press-$v" OrangeDrinkUITests/FirstLaunchUITests/testBluetoothIsAllowed TEST_RUNNER_INSTALLED_APP="$app" || echo "no prompt to press for $v"
  sleep 5
  guest cat "/tmp/spike-$v.log" | grep -v ' beat ' 
  guest sh -c "tail -1 /tmp/spike-$v.log"
  guest pkill -f "BTSpike-$v.app" || true
done
# A rebuild: the same bundle id with a new code signature, which is what every ad-hoc Debug build is to tccd. Does the
# authorization read not determined, or a stale allowed that would send the registration to the main thread unanswered?
if [[ " ${variants[*]} " == *" central "* ]]; then
  a=/Users/admin/Applications/BTSpike-central.app
  echo "=== central, rebuilt, prompt unanswered"
  guest sh -c "cp '$shared/rebuilt' '$a/Contents/MacOS/spike' && codesign -f -s - '$a' && rm /tmp/spike-central.log"
  guest open "$a"
  sleep 10
  guest cat /tmp/spike-central.log | grep -vE ' beat ([2-9]|[1-9][0-9])$'
fi
