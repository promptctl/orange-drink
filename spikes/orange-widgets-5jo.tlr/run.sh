#!/bin/bash
# The spike's steps (README.md gives the order). Built on a Mac with the Developer ID identity;
# installed and measured on the Mac under test, which may be another one.
#   run.sh build release|debug      build one variant into build/OrangeWidgetSpike-<variant>.zip
#   run.sh ship release|debug HOST  build, copy the zip and this script to HOST, install there
#   run.sh install ZIP              install the zip in /Applications, write seq 0, print its signing
#   run.sh reload EVERY TIMES FROM  write TIMES levels EVERY seconds apart from sequence FROM, reloading after each
#   run.sh uninstall                remove the app, every registration of its widget, and both containers
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

app=OrangeWidgetSpike
installed=/Applications/$app.app
widget_id=dev.orangedrink.widgetspike.widget
group=6R988MUU27.dev.orangedrink.widgetspike
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
remote_dir=/tmp/orange-widgets-5jo.tlr

# Waits, up to 30 s, for pluginkit's answer about the widget to be $1: "listed" or "absent".
await_registration() {
  for _ in $(seq 30); do
    listing=$(pluginkit -m -v -i "$widget_id")
    state=absent
    if grep -qF "$widget_id" <<<"$listing"; then state=listed; fi
    if [ "$state" = "$1" ]; then echo "pluginkit: $listing"; return; fi
    sleep 1
  done
  echo "pluginkit never showed $widget_id $1; last answer: '$listing'" >&2
  exit 1
}

uninstall() {
  if pgrep -x "$app" >/dev/null; then pkill -x "$app"; fi
  # LaunchServices registers every copy it meets, the build products' as well as the installed one.
  pluginkit -m -v -i "$widget_id" | awk -F'\t' '/\.appex$/ { print $NF }' | while read -r appex; do
    pluginkit -r "$appex"
    "$lsregister" -u "${appex%/Contents/PlugIns/*}"
  done
  rm -rf "$installed" "$HOME/Library/Group Containers/$group" "$HOME/Library/Containers/$widget_id"
  await_registration absent
}

build() {
  # [LAW:dataflow-not-control-flow] The variant is the configuration and signature the app's own Debug
  # and Release builds use (Debug adds get-task-allow); the entitlements files and the steps are the same.
  case "$1" in
    release)
      # [LAW:one-source-of-truth] The release identity and team are the app's own, named as scripts/dmg names them.
      source "$here/../../scripts/developer-id"
      config=Release; signing=("CODE_SIGN_IDENTITY=Developer ID Application: $developer_id" "DEVELOPMENT_TEAM=$developer_team") ;;
    debug) config=Debug; signing=() ;;
    *) echo "variant must be release or debug, not '$1'" >&2; exit 64 ;;
  esac
  (cd "$here" && xcodegen generate)
  xcodebuild -quiet -project "$here/$app.xcodeproj" -target "$app" -configuration "$config" \
    SYMROOT="$here/build/products" ${signing[@]+"${signing[@]}"} build
  zip=$here/build/$app-$1.zip
  rm -f "$zip"
  ditto -c -k --keepParent "$here/build/products/$config/$app.app" "$zip"
  # Xcode registered the build products here; the Mac that builds is not the Mac under test.
  uninstall
  echo "$zip"
}

ship() {
  zip=$(build "$1" | tail -n 1)
  ssh "$2" mkdir -p "$remote_dir"
  scp -q "$zip" "$here/run.sh" "$here/measure.sh" "$2:$remote_dir/"
  ssh "$2" bash "$remote_dir/run.sh" install "$remote_dir/$(basename "$zip")"
}

install() {
  uninstall
  ditto -x -k "$1" /Applications
  for bundle in "$installed" "$installed/Contents/PlugIns/${app}Widget.appex"; do
    codesign -dvv "$bundle" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Signature)='
    codesign -d --entitlements - --xml "$bundle" | plutil -p -
  done
  spctl --assess --type execute -vv "$installed" 2>&1 || echo "spctl: rejected (status $?)"
  reload 0 1 0
  await_registration listed
}

# Each reload is a new host (-n), so a host still running never swallows these arguments. open
# returns its own status, never the host's, so the host reports a failure on stderr instead.
reload() {
  errors=$(mktemp)
  open -n -W --stderr "$errors" "$installed" --args --every "$1" --times "$2" --from "$3"
  failure=$(cat "$errors")
  rm "$errors"
  if [ -n "$failure" ]; then echo "$app failed: $failure" >&2; exit 1; fi
}

command=${1:?"usage: run.sh build|ship|install|reload|uninstall (see the top of run.sh)"}
shift
"$command" "$@"
