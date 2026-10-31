#!/bin/bash
# [LAW:behavior-not-structure] The release scripts seen from outside: scripts/version, release-preflight,
# release-keychain and notarize, each run from a scratch copy of the tree with security, xcrun, base64 and
# spctl stood in on PATH. The stand-ins record every call to $SCRATCH/calls; each case asserts what was
# printed, how it exited, and what was called. Trust, validation and real signing are proved by a release
# run, not here.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export SCRATCH=$scratch

mkdir "$scratch/bin"
for tool in security xcrun base64 spctl; do
  cat > "$scratch/bin/$tool" <<'STUB'
#!/bin/bash
echo "$(basename "$0") $*" >>"$SCRATCH/calls"
case "$(basename "$0") $1 $2" in
  "security list-keychains -d")
    [ "$3" = user ] && [ $# -eq 3 ] || exit 0
    [ ! -e "$SCRATCH/list-fails" ] || { echo "list-keychains broke" >&2; exit 1; }
    [ -e "$SCRATCH/list-empty" ] || printf '    "/Users/me/Library/Keychains/login.keychain-db"\n    "/Users/me/Library/Keychains/my keys.keychain-db"\n' ;;
  "security import"*) [ ! -e "$SCRATCH/import-fails" ] || exit 1 ;;
  "xcrun notarytool submit") cat "$SCRATCH/submit.json" ;;
  "xcrun notarytool log") echo "the notary log" ;;
  "base64 --decode "*) [ ! -e "$SCRATCH/decode-fails" ] || exit 1; cat ;;
  "spctl --assess"*) echo "$SCRATCH/x: accepted" >&2; echo "source=Notarized Developer ID" >&2 ;;
esac
exit 0
STUB
  chmod +x "$scratch/bin/$tool"
done
export PATH="$scratch/bin:$PATH"
# The scratch repository's git ignores this machine's config: a global tag.gpgSign or core.hooksPath would
# otherwise sign, prompt or refuse in it.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

failed=0
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; failed=1; }
# expect <name> <status> <output fragment> -- <command...>: runs the command, asserts its status and that its
# stdout and stderr together contain the fragment.
expect() {
  local name=$1 status=$2 fragment=$3; shift 4
  local out code=0
  out=$("$@" 2>&1) || code=$?
  if [ "$code" = "$status" ] && grep -qF -- "$fragment" <<<"$out"; then pass "$name"
  else fail "$name: exited $code (wanted $status), printed: $out"; fi
}
called() { grep -qF -- "$1" "$scratch/calls" 2>/dev/null; }
calls_reset() { rm -f "$scratch/calls"; }

# A scratch tree: the scripts under test beside a project.yml whose MARKETING_VERSION line is $1.
tree() {
  local dir=$scratch/tree
  rm -rf "$dir"; mkdir -p "$dir/scripts"
  cp "$repo/scripts/version" "$repo/scripts/release-preflight" "$repo/scripts/release-keychain" \
     "$repo/scripts/notarize" "$repo/scripts/developer-id" "$dir/scripts/"
  sed "s/^\(  *\)MARKETING_VERSION:.*/\1$1/" "$repo/project.yml" >"$dir/project.yml"
  echo "$dir"
}

# --- scripts/version
t=$(tree 'MARKETING_VERSION: "1.2.3"')
expect "a quoted version is read without its quotes" 0 "1.2.3" -- "$t/scripts/version"
[ "$("$t/scripts/version")" = 1.2.3 ] && pass "the version is the whole output" || fail "the version is the whole output"
t=$(tree 'MARKETING_VERSION: 4.5.6')
expect "an unquoted version is read" 0 "4.5.6" -- "$t/scripts/version"
t=$(tree 'NOT_A_VERSION_KEY: 1')
expect "a missing MARKETING_VERSION is refused" 1 "has 0 MARKETING_VERSION lines" -- "$t/scripts/version"
t=$(tree 'MARKETING_VERSION: "1.2"')
expect "a value that is not three numbers is refused, naming it" 1 'is not a version: "1.2"' -- "$t/scripts/version"
t=$(tree 'MARKETING_VERSION: 1.2.3')
echo '    MARKETING_VERSION: 9.9.9' >>"$t/project.yml"
expect "a repeated MARKETING_VERSION is refused" 1 "has 2 MARKETING_VERSION lines" -- "$t/scripts/version"

# --- scripts/release-preflight, in a git repository whose master is origin/master
t=$(tree 'MARKETING_VERSION: "1.2.3"')
(
  cd "$t"
  git init -q -b master && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m master
  git update-ref refs/remotes/origin/master HEAD
  git tag v1.2.3 && git tag v9.9.9
  git checkout -q -b branch && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m branch
  git tag v1.2.3-branch
)
pre() { (cd "$t" && scripts/release-preflight "$@"); }
expect "a tag naming the version, on master, passes" 0 "v1.2.3 is v1.2.3 at" -- pre v1.2.3
expect "a tag naming another version is refused before building" 1 "tag v9.9.9 is not v1.2.3, project.yml's MARKETING_VERSION" -- pre v9.9.9
# The version check passes, so only the master check can refuse: the tag on the branch commit is moved to v1.2.3.
(cd "$t" && git tag -f v1.2.3 branch >/dev/null)
expect "a tag naming the version off master is refused" 1 "v1.2.3 is not on master" -- pre v1.2.3
expect "a tag naming another version off master is refused by the version, the first check" 1 "tag v1.2.3-branch is not v1.2.3" -- pre v1.2.3-branch
(cd "$t" && git tag -f v1.2.3 master >/dev/null && git update-ref -d refs/remotes/origin/master)
expect "a checkout without origin/master says so, not that the tag is off master" 1 "this checkout has no origin/master to judge v1.2.3 against" -- pre v1.2.3

# --- scripts/release-keychain
t=$(tree 'MARKETING_VERSION: "1.2.3"')
secrets() {
  export RUNNER_ENVIRONMENT=github-hosted NOTARY_KEYCHAIN="$scratch/release.keychain-db" \
    DEVELOPER_ID_APPLICATION_P12=cDEy DEVELOPER_ID_P12_PASSWORD=pw NOTARY_APPLE_ID=me@example.com NOTARY_PASSWORD=app-pw
}
calls_reset; secrets; RUNNER_ENVIRONMENT=self-hosted
expect "release-keychain refuses outside a GitHub-hosted runner" 1 "refusing to run outside a GitHub-hosted runner (RUNNER_ENVIRONMENT is 'self-hosted')" -- "$t/scripts/release-keychain"
[ ! -e "$scratch/calls" ] && pass "outside a hosted runner nothing is called" || fail "outside a hosted runner nothing is called: $(cat "$scratch/calls")"
calls_reset; secrets; unset RUNNER_ENVIRONMENT
expect "release-keychain refuses with RUNNER_ENVIRONMENT unset" 1 "RUNNER_ENVIRONMENT is ''" -- "$t/scripts/release-keychain"
calls_reset; secrets; NOTARY_PASSWORD= ; unset NOTARY_KEYCHAIN
expect "release-keychain names every missing secret and the keychain" 1 "these are not set: NOTARY_KEYCHAIN NOTARY_PASSWORD" -- "$t/scripts/release-keychain"
[ ! -e "$scratch/calls" ] && pass "with a secret missing nothing is called" || fail "with a secret missing nothing is called: $(cat "$scratch/calls")"
calls_reset; secrets; touch "$scratch/import-fails"
expect "an identity that will not import fails, naming the secret" 1 "DEVELOPER_ID_APPLICATION_P12 would not import" -- "$t/scripts/release-keychain"
rm -f "$scratch/import-fails"
calls_reset; secrets; touch "$scratch/decode-fails"
expect "a secret that is not base64 fails, naming it" 1 "DEVELOPER_ID_APPLICATION_P12 is not base64" -- "$t/scripts/release-keychain"
rm -f "$scratch/decode-fails"
for failure in "list-empty:the keychain search list read as empty" "list-fails:list-keychains broke"; do
  marker=${failure%%:*}
  calls_reset; secrets; touch "$scratch/$marker"
  expect "$marker stops release-keychain" 1 "${failure#*:}" -- "$t/scripts/release-keychain"
  called "security list-keychains -d user -s" && fail "$marker rewrote the search list" || pass "$marker leaves the search list alone"
  rm -f "$scratch/$marker"
done
calls_reset; secrets
expect "release-keychain makes the keychain" 0 "holds the Developer ID identity and notary profile orange-drink-notary" -- "$t/scripts/release-keychain"
k=$NOTARY_KEYCHAIN
# Every call, whole and in order; * stands only for the random keychain password and the decoded .p12's
# temporary path. So a call that names another keychain, an extra call, or a lock timer (-t) fails.
want=(
  "security create-keychain -p * $k"
  "security set-keychain-settings $k"
  "security unlock-keychain -p * $k"
  "base64 --decode"
  "security import * -k $k -f pkcs12 -P pw -T /usr/bin/codesign"
  "security set-key-partition-list -S apple-tool:,apple: -k * $k"
  "security list-keychains -d user"
  "security list-keychains -d user -s $k /Users/me/Library/Keychains/login.keychain-db /Users/me/Library/Keychains/my keys.keychain-db"
  "xcrun notarytool store-credentials orange-drink-notary --keychain $k --apple-id me@example.com --team-id 6R988MUU27 --password app-pw"
)
got=$(cat "$scratch/calls")
i=0; exact=1
while IFS= read -r line; do
  [ $i -lt ${#want[@]} ] && [[ $line == ${want[$i]} ]] || { exact=0; break; }
  i=$((i + 1))
done <<<"$got"
[ $exact = 1 ] && [ $i -eq ${#want[@]} ] \
  && pass "the calls are exactly these, in order: one keychain, no lock timer, the old search list kept, developer-id's profile and team" \
  || fail "the calls are exactly these (call $((i + 1)) wanted '${want[$i]:-nothing more}'): $got"
unset RUNNER_ENVIRONMENT NOTARY_KEYCHAIN DEVELOPER_ID_APPLICATION_P12 DEVELOPER_ID_P12_PASSWORD NOTARY_APPLE_ID NOTARY_PASSWORD

# --- scripts/notarize: where notarytool finds the profile
t=$(tree 'MARKETING_VERSION: "1.2.3"')
touch "$scratch/image.dmg"
echo '{"status":"Accepted","id":"sub-1"}' >"$scratch/submit.json"
calls_reset
expect "notarize accepts an image Gatekeeper calls notarized" 0 "$scratch/image.dmg" -- "$t/scripts/notarize" "$scratch/image.dmg"
called "xcrun notarytool submit $scratch/image.dmg --keychain-profile orange-drink-notary --wait --timeout 30m --output-format json" \
  && pass "with NOTARY_KEYCHAIN unset, submit names no keychain" || fail "with NOTARY_KEYCHAIN unset, submit names no keychain: $(cat "$scratch/calls")"
calls_reset
NOTARY_KEYCHAIN="$scratch/job keys.keychain-db" expect "notarize runs with the job's keychain" 0 "$scratch/image.dmg" -- "$t/scripts/notarize" "$scratch/image.dmg"
called "xcrun notarytool submit $scratch/image.dmg --keychain-profile orange-drink-notary --keychain $scratch/job keys.keychain-db --wait" \
  && pass "with NOTARY_KEYCHAIN set, submit names that keychain" || fail "with NOTARY_KEYCHAIN set, submit names that keychain: $(cat "$scratch/calls")"
echo '{"status":"Invalid","id":"sub-2"}' >"$scratch/submit.json"
calls_reset
NOTARY_KEYCHAIN="$scratch/job keys.keychain-db" expect "a refused submission fails with its log" 1 "the notary log" -- "$t/scripts/notarize" "$scratch/image.dmg"
called "xcrun notarytool log sub-2 --keychain-profile orange-drink-notary --keychain $scratch/job keys.keychain-db" \
  && pass "the log is fetched from the same keychain" || fail "the log is fetched from the same keychain: $(cat "$scratch/calls")"

exit $failed
