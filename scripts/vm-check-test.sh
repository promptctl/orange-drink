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
    $body" 2>/dev/null || status=$?
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

sed -i '' 's/^exit 0$/[ "$1" != get ]/' "$scratch/bin/tart"
run_check "$listed" ':'
expect_status 1 "no image"
expect_calls 'tart get ' "no image"
expect_no_scratch "no image"
ok "a missing image stops the run before a clone"
