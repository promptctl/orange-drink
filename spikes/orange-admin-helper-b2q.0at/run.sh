#!/bin/bash
# The spike's steps (README.md gives the order). Built on a Mac with the Developer ID identity; run on
# the Mac under test, which may be another one.
#   run.sh build adhoc|devid VERSION            build into build/HelperSpike-<variant>-<VERSION>.zip
#   run.sh ship adhoc|devid VERSION HOST DIR    build, copy to HOST, place the app in DIR there
#   run.sh place ZIP DIR                        replace DIR/HelperSpike.app, sign the impostor, print signing
#   run.sh register|status|unregister|call      run the placed app with that argument
#   run.sh impostor                             call the helper from the impostor
#   run.sh helper-state                         launchd's view of the helper: state, pid, program
#   run.sh stop-helper                          stop the running helper so launchd starts it afresh
#   run.sh bootstrap|bootout                    load or unload the helper the legacy way, without SMAppService
#   run.sh uninstall                            unregister, remove the app, require BTM to have forgotten it
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

remote_dir=/tmp/orange-admin-helper-b2q.0at
placed_file=$remote_dir/placed

app() {
  [ -f "$placed_file" ] || { echo "nothing placed (no $placed_file)" >&2; exit 1; }
  cat "$placed_file"
}

# [LAW:one-source-of-truth] The label is the embedded launchd plist's, read back from the placed app.
label() { plutil -extract Label raw "$(app)"/Contents/Library/LaunchDaemons/*.plist; }

build() {
  # [LAW:dataflow-not-control-flow] The variant is the signing and nothing else: master's ad-hoc
  # `make build`, or the Developer ID Debug build PR #11 makes of every build.
  case "$1" in
    adhoc) signing=() ;;
    devid)
      # [LAW:one-source-of-truth] The identity and team are the app's own, named as scripts/dmg names them.
      source "$here/../../scripts/developer-id"
      signing=("CODE_SIGN_IDENTITY=Developer ID Application: $developer_id" "DEVELOPMENT_TEAM=$developer_team") ;;
    *) echo "variant must be adhoc or devid, not '$1'" >&2; exit 64 ;;
  esac
  # Each variant builds in a directory of its own, so no product of one is signed as the other.
  products=$here/build/products-$1
  (cd "$here" && xcodegen generate >&2)
  xcodebuild -quiet -project "$here/HelperSpike.xcodeproj" -alltargets -configuration Debug \
    SYMROOT="$products" OBJROOT="$products/obj" CURRENT_PROJECT_VERSION="$2" ${signing[@]+"${signing[@]}"} build >&2
  stage=$here/build/stage
  rm -rf "$stage" && mkdir -p "$stage"
  ditto "$products/Debug/HelperSpike.app" "$stage/HelperSpike.app"
  cp "$products/Debug/Impostor" "$stage/"
  zip=$here/build/HelperSpike-$1-$2.zip
  rm -f "$zip"
  ditto -c -k "$stage" "$zip"
  echo "$zip"
}

ship() {
  zip=$(build "$1" "$2")
  ssh "$3" mkdir -p "$remote_dir"
  scp -q "$zip" "$here/run.sh" "$3:$remote_dir/"
  ssh "$3" bash "$remote_dir/run.sh" place "$remote_dir/$(basename "$zip")" "$4"
}

place() {
  mkdir -p "$2"
  rm -rf "$2/HelperSpike.app" "$remote_dir/Impostor"
  ditto -x -k "$1" "$remote_dir/unpacked"
  mv "$remote_dir/unpacked/HelperSpike.app" "$2/"
  mv "$remote_dir/unpacked/Impostor" "$remote_dir/"
  rm -rf "$remote_dir/unpacked"
  echo "$2/HelperSpike.app" >"$placed_file"
  # The impostor is other code wearing the app's identifier, signed the way any local process can sign.
  codesign -f -s - -i "$(plutil -extract CFBundleIdentifier raw "$(app)/Contents/Info.plist")" "$remote_dir/Impostor" 2>&1
  for code in "$(app)" "$(app)/Contents/MacOS/HelperSpikeHelper" "$remote_dir/Impostor"; do
    echo "== $code"
    codesign -dvvv "$code" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Signature|CDHash)='
    codesign -d -r- "$code" 2>&1 | grep 'designated'
  done
  codesign -d --entitlements - --xml "$(app)" 2>/dev/null | plutil -p - || echo "(no entitlements)"
}

# open returns its own status, never the app's, so the app's stderr is the failure. The app can exit
# before `open -W` attaches to it, so the wait is for the line App/main.swift prints on every exit.
run_app() {
  out=$(mktemp) && errors=$(mktemp)
  open -n --stdout "$out" --stderr "$errors" "$(app)" --args "$1"
  for _ in $(seq 150); do
    if grep -qx -- '-- end of run' "$out"; then break; fi
    sleep 0.1
  done
  grep -qx -- '-- end of run' "$out" || echo "the app never finished; stdout so far: $(cat "$out")" >>"$errors"
  grep -vx -- '-- end of run' "$out" || true
  failure=$(cat "$errors")
  rm "$out" "$errors"
  if [ -n "$failure" ]; then echo "$failure" >&2; exit 1; fi
}

register() { run_app register; }
status() { run_app status; }
unregister() { run_app unregister; }
call() { run_app call; }

# The Mach service is the one key of the plist's MachServices.
service() { /usr/libexec/PlistBuddy -c 'Print :MachServices' "$(app)"/Contents/Library/LaunchDaemons/*.plist | awk '$2 == "=" { print $1 }'; }

impostor() { "$remote_dir/Impostor" "$(service)"; }

helper-state() {
  launchctl print "system/$(label)" 2>&1 | grep -E '^\s+(state|pid|program|path) =' || echo "launchd has no system/$(label)"
}

stop-helper() {
  sudo -n launchctl kill TERM "system/$(label)"
  sleep 1
  helper-state
}

# The same helper, loaded the legacy way, which needs no approval in Login Items: the embedded plist
# with BundleProgram swapped for the absolute path. It answers the authentication half of the
# question while approval waits for a person; SMAppService itself never sees this job.
manual_plist=$remote_dir/manual.plist

bootstrap() {
  sudo -n rm -f "$manual_plist"
  cp "$(app)"/Contents/Library/LaunchDaemons/*.plist "$remote_dir/manual-draft.plist"
  plutil -remove BundleProgram "$remote_dir/manual-draft.plist"
  plutil -insert Program -string "$(app)/Contents/MacOS/HelperSpikeHelper" "$remote_dir/manual-draft.plist"
  sudo -n install -o root -g wheel -m 644 "$remote_dir/manual-draft.plist" "$manual_plist"
  rm "$remote_dir/manual-draft.plist"
  sudo -n launchctl bootstrap system "$manual_plist"
  helper-state
}

bootout() {
  sudo -n launchctl bootout "system/$(label)"
  sudo -n rm -f "$manual_plist"
  helper-state
}

uninstall() {
  if [ -f "$placed_file" ] && [ -d "$(app)" ]; then
    run_app unregister
    if launchctl print "system/$(label)" >/dev/null 2>&1; then echo "launchd still has system/$(label)" >&2; exit 1; fi
    rm -rf "$(app)"
  fi
  rm -f "$placed_file" "$remote_dir/Impostor"
  # Reading BTM takes root; where sudo needs a password, unregister's status is the evidence.
  if ! sudo -n true 2>/dev/null; then echo "BTM unread: sudo needs a password here"; return; fi
  if sudo -n sfltool dumpbtm | grep -q helperspike; then
    echo "BTM still lists helperspike:" >&2
    sudo -n sfltool dumpbtm | grep -B3 -A12 helperspike >&2
    exit 1
  fi
  echo "BTM lists no helperspike"
}

command=${1:?"usage: run.sh build|ship|place|register|status|unregister|call|impostor|helper-state|stop-helper|uninstall (see the top of run.sh)"}
shift
"$command" "$@"
