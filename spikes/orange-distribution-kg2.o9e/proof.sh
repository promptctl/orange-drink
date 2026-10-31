#!/bin/sh
# Runs in the VM, from run.sh. Every value printed is read from the VM; nothing is shown on the Mac running it.
set -eu
run="/Volumes/My Shared Files/run"
banners="$run/banners"
battery="$run/fake-battery"
step() { echo; echo "=== $*"; }
other() { osascript -e "display notification \"$2\" with title \"$1\""; }
words='Your Mac will sleep soon unless plugged into a power outlet.'

step "$(sw_vers -productVersion) $(sw_vers -buildVersion)"
ls /System/Library/UserNotifications/Bundles | grep -i -E 'batter'
ls "/System/Library/UserNotifications/Bundles/com.apple.controlcenter.notifications.low-battery.bundle/Contents/Resources" | grep -i -E 'table|^en.lproj'

step "a stand-in battery, and ControlCenter restarted to build its Battery module"
sudo -n "$battery" 4 6 420 &
sleep 3
sudo -n "$battery" warn 1
killall ControlCenter
sleep 8
pmset -g batt

step "Script Editor allowed banners, the Allow a person gives, which macOS 15 and 26 ask for before a new app's first"
other 'First' 'Registers Script Editor with Notification Center'
prefs=/tmp/ncprefs.plist
allow() {
  defaults export com.apple.ncprefs "$prefs"
  app=0
  while bundle=$(/usr/libexec/PlistBuddy -c "Print :apps:$app:bundle-id" "$prefs" 2>/dev/null); do
    if [ "$bundle" = com.apple.ScriptEditor2 ]; then
      flags=$(/usr/libexec/PlistBuddy -c "Print :apps:$app:flags" "$prefs")
      /usr/libexec/PlistBuddy -c "Set :apps:$app:flags $((flags | 1 << 25))" "$prefs"
      defaults import com.apple.ncprefs "$prefs"
      return 0
    fi
    app=$((app + 1))
  done
  return 1
}
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do allow && break; sleep 1; done
killall usernoted NotificationCenter
sleep 6
other 'First' 'A banner'
"$banners" wait 1 10
"$banners" list
sleep 8

step "the final warning, and another app with the same words a second later"
"$banners" observe 8 &
observer=$!
"$banners" closer 2 14 &
closer=$!
sleep 1
sudo -n "$battery" warn 3
sleep 1
other 'Low Battery' "$words"
wait "$closer"
wait "$observer"

step "closed: the same warning level again, with no change, does not bring it back"
sudo -n "$battery" warn 3
sleep 2
"$banners" wait 0 1
"$banners" list

step "the panel open over the final warning"
sudo -n "$battery" warn 1
sleep 1
sudo -n "$battery" warn 3
sleep 2
"$banners" panel
sleep 2
"$banners" list
"$banners" close
"$banners" wait 1 3
"$banners" list
"$banners" panel
sleep 2

step "the early warning: a notification on macOS 14 and 15, none on 26"
sudo -n "$battery" warn 1
sleep 1
sudo -n "$battery" warn 2
sleep 2
"$banners" list

step "the final warning over the early one left showing, the order a discharge reaches them"
sudo -n "$battery" warn 3
sleep 2
"$banners" list
"$banners" close
"$banners" wait 0 3
"$banners" list

step "the final warning after the early one was closed"
sudo -n "$battery" warn 1
sleep 1
sudo -n "$battery" warn 2
sleep 2
"$banners" close
"$banners" wait 0 3
sudo -n "$battery" warn 3
sleep 2
"$banners" list
"$banners" close
"$banners" wait 0 3

step "the final warning with the suppression preference on: nothing posted"
sudo -n "$battery" warn 1
sleep 1
defaults write com.apple.menuextra.battery suppresUserNotifications -bool true
sudo -n "$battery" warn 3
sleep 3
"$banners" wait 0 1
"$banners" list

step "the preference off, and the warning raised again: posted"
defaults delete com.apple.menuextra.battery suppresUserNotifications
sudo -n "$battery" warn 1
sleep 1
sudo -n "$battery" warn 3
"$banners" wait 1 3
"$banners" list

step "the warning withdrawn with the power: macOS hides it itself"
sudo -n "$battery" warn 1
"$banners" wait 0 3
"$banners" list

for language in fr-FR ja zh-Hans ar; do
  step "a Mac in $language: the words, the description's punctuation, and the Close action, found and closed"
  sudo -n "$battery" warn 1
  defaults write -g AppleLanguages -array "$language" en
  killall ControlCenter NotificationCenter usernoted
  sleep 10
  sudo -n "$battery" warn 3
  "$banners" wait 1 10
  "$banners" list
  "$banners" close
  "$banners" wait 0 3
  "$banners" list
done

step "com.apple.battery-monitor, the other bundle with these words: its helper is the only thing that could post from it"
helper="/System/Library/CoreServices/Menu Extras/Battery.menu/Contents/Resources/bmehelper"
if [ -e "$helper" ]; then echo "bmehelper is there"; else echo "bmehelper is missing"; fi
launchctl print "gui/$(id -u)/com.apple.menuextra.battery.helper" | grep -E '^[[:space:]]*(state|runs) ='

step "ControlCenter's own log"
log show --last 6m --process ControlCenter --info --style compact | grep -E 'Low Battery Notification|suppress warnings|warning level'
