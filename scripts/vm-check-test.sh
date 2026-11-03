#!/bin/bash
# [LAW:behavior-not-structure] scripts/vm-check-lib seen from a check that sources it, with tart stood in on PATH. The
# stand-in records every call to $SCRATCH/calls; each case asserts how the run ended, what tart was asked, and what was
# left behind. A real check passing never reaches these failure paths, and one of them removes a private key.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export SCRATCH=$scratch

mkdir "$scratch/bin" "$scratch/products"
touch "$scratch/products/Tests.xctestrun"
cat >"$scratch/bin/tart" <<'STUB'
#!/bin/bash
echo "tart $1" >>"$SCRATCH/calls"
exit 0
STUB
chmod +x "$scratch/bin/tart"
export PATH=$scratch/bin:$PATH

# Runs a check that sources the lib, sets up its cleanup with `$1`, and runs `$2` as its body.
run_check() {
  local cleanup=$1 body=$2
  : >"$scratch/calls"
  rm -rf "$scratch/secret" "$scratch/failure-logs"
  mkdir "$scratch/secret"
  status=0
  TMPDIR=$scratch /bin/bash -c "set -euo pipefail
    . '$repo/scripts/vm-check-lib'
    $cleanup
    on_failure() { touch '$scratch/failure-logs'; }
    $body" 2>"$scratch/stderr" || status=$?
}
ok() { echo "ok: $1"; }
broken() { echo "FAILED: $1" >&2; exit 1; }
expect_status() { [ "$status" -eq "$1" ] || broken "$2: exit $status, not $1"; }
expect_calls() { [ "$(tr '\n' ' ' <"$scratch/calls")" = "$1" ] || broken "$2: tart was asked: $(tr '\n' ' ' <"$scratch/calls")"; }
expect_no_scratch() { ! compgen -G "$scratch/orangedrink-vm-check.*" >/dev/null || broken "$1: the scratch directory stayed"; }
expect_removed() {
  expect_no_scratch "$1"
  [ ! -e "$scratch/secret" ] || broken "$1: a listed directory stayed"
}

listed="vm_cleanup=('$scratch/secret')"
started='vm_start "$SCRATCH/products/Tests.xctestrun"'

run_check "$listed" 'exit 3'
expect_status 3 "a failure before the clone"
expect_calls 'tart get ' "a failure before the clone"
expect_removed "a failure before the clone"
[ ! -e "$scratch/failure-logs" ] || broken "a failure before the clone asked a VM that does not exist for logs"
ok "a failure before the clone starts no VM, keeps its status, and removes the listed directories"

run_check "$listed" "$started; fail 'nope'"
expect_status 1 "a failure in the VM"
expect_removed "a failure in the VM"
[ -e "$scratch/failure-logs" ] || broken "a failure in the VM printed no logs"
grep -q 'tart stop' "$scratch/calls" || broken "a failure in the VM left it running"
grep -q 'tart delete' "$scratch/calls" || broken "a failure in the VM left it on disk"
ok "a failure in the VM prints its logs, stops and deletes it, and removes the listed directories"

for image_name in orange-drink-xcode ghcr.io/cirruslabs/macos-sonoma-base:latest; do
  # A reading that failed through `fail` says why; a command that failed under errexit says its status.
  for ending in "fail 'nope'|nope" "false|exited 1"; do
    run_check "$listed" "image=$image_name; $started; ${ending%%|*}"
    grep -qxF "» failure: bash on $image_name: ${ending##*|}" "$scratch/stderr" ||
      broken "the marked line for \"${ending%%|*}\" on $image_name was not 'bash on $image_name: ${ending##*|}': $(cat "$scratch/stderr")"
  done
done
ok "a failed run's marked line names the image it ran on, and why when it said"

run_check "$listed" "$started; on_failure() { false; }; exit 4"
expect_status 4 "a failing on_failure"
grep -q 'tart delete' "$scratch/calls" || broken "a failing on_failure left the VM on disk"
ok "a failing on_failure still ends the VM, and the run keeps its status"

run_check "$listed" "$started"
expect_status 0 "a passing run"
expect_removed "a passing run"
[ ! -e "$scratch/failure-logs" ] || broken "a passing run asked for failure logs"
grep -q 'tart delete' "$scratch/calls" || broken "a passing run left the VM on disk"
ok "a passing run ends the VM with no logs and removes the listed directories"

run_check ":" "$started; uitest Some/test"
expect_status 0 "empty lists"
grep -q 'tart delete' "$scratch/calls" || broken "an empty vm_cleanup ended the trap before the VM was deleted"
ok "empty lists work under set -u on macOS's bash"

: >"$scratch/calls"
status=0
TMPDIR=$scratch /bin/bash -c "set -euo pipefail
  image=another-image
  . '$repo/scripts/vm-check-lib'
  vm_boot" 2>/dev/null || status=$?
expect_status 0 "a check on another image"
grep -q 'tart clone' "$scratch/calls" || broken "vm_boot did not clone"
[ "$(grep -c 'tart exec' "$scratch/calls")" -eq 1 ] || broken "vm_boot asked more of the guest than whether it is up"
ok "a check can name its image, and vm_boot needs no Xcode in it"

# scripts/notification-vm-lib's reading of the tree's alerts, with the tree and the warning stood in: which alerts are new, and what
# `raise` asks of powerd before it says one showed.
tab=$'\t'
alert_a="AXNotificationCenterAlert${tab}Low Battery${tab}b${tab}d"
alert_b="AXNotificationCenterAlert${tab}Login Items${tab}b${tab}d"
banner="AXNotificationCenterBanner${tab}Low Battery${tab}b${tab}Mail, d"
in_lib() {
  TMPDIR=$scratch /bin/bash -c "set -euo pipefail
    . '$repo/scripts/vm-check-lib'
    . '$repo/scripts/notification-vm-lib'
    $1"
}
[ "$(in_lib "new_alerts '$alert_a
$banner
$alert_b' ''")" = "$alert_a
$alert_b" ] || broken "with no baseline, every alert and no banner is new"
[ "$(in_lib "new_alerts '$alert_a
$banner
$alert_b' '$alert_b'")" = "$alert_a" ] || broken "an alert in the baseline is not new"
[ -z "$(in_lib "new_alerts '$banner' ''")" ] || broken "a banner is not an alert"
ok "new_alerts lists the alerts beyond its baseline, and none when only a banner or the baseline shows"

: >"$scratch/warns"
raised="warn() { echo \"warn \$1\" >>'$scratch/warns'; }; sleep() { :; }"
status=0
in_lib "$raised; list() { printf '%s\n' '$alert_a'; }; raise 3 ''" || status=$?
expect_status 0 "an alert showing after the warning"
[ "$(tr '\n' ' ' <"$scratch/warns")" = 'warn 1 warn 3 ' ] || broken "raise did not withdraw the warning, then raise it: $(cat "$scratch/warns")"
status=0
in_lib "$raised; list() { printf '%s\n' '$alert_a'; }; raise 3 '$alert_a'" || status=$?
expect_status 1 "only the baseline's alert showing"
ok "raise withdraws the warning, raises it, and succeeds only for an alert beyond its baseline"

# `withdrawn`, with `list` showing the alert until the warning has gone 3 then 1, as macOS 26's stuck alert did.
withdraw() {
  : >"$scratch/warns"
  status=0
  in_lib "$raised; $1; withdrawn" || status=$?
}
expect_warns() { [ "$(tr '\n' ' ' <"$scratch/warns")" = "$1" ] || broken "$2: the warning was sent as: $(tr '\n' ' ' <"$scratch/warns")"; }
withdraw 'list() { :; }'
expect_status 0 "nothing showing"
expect_warns '' "nothing showing"
withdraw "list() { [ \"\$(tr '\\n' ' ' <'$scratch/warns')\" = 'warn 3 warn 1 ' ] || printf '%s\\n' '$alert_a'; }"
expect_status 0 "an alert that goes when the level changes"
expect_warns 'warn 3 warn 1 ' "an alert that goes when the level changes"
withdraw "list() { printf '%s\\n' '$alert_a'; }"
expect_status 1 "an alert that stays"
expect_warns 'warn 3 warn 1 ' "an alert that stays"
withdraw 'list() { return 1; }'
expect_status 1 "a tree that could not be read"
expect_warns '' "a tree that could not be read"
ok "withdrawn sends nothing for an empty or unreadable tree, changes the level 3 then 1 for one showing, and succeeds only once nothing shows"

[ "$(in_lib "as_literal 'say \"hi\" \\ it’s'")" = 'say \"hi\" \\ it’s' ] || broken "as_literal did not escape a quote and a backslash"
ok "as_literal escapes the quote and backslash that would end an AppleScript string"

sed -i '' 's/^exit 0$/[ "$1" != get ]/' "$scratch/bin/tart"
run_check "$listed" ':'
expect_status 1 "no image"
expect_calls 'tart get ' "no image"
expect_no_scratch "no image"
ok "a missing image stops the run before a clone"
