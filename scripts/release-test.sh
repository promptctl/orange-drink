#!/bin/bash
# [LAW:behavior-not-structure] The release scripts seen from outside: scripts/version, release-preflight,
# release-keychain, release-publish, notarize, dmg and appcast, each run from a scratch copy of the tree with the tools
# they call stood in on PATH. The stand-ins record every call to $SCRATCH/calls; each case asserts what was
# printed, how it exited, and what was called. Trust, validation and real signing are proved by a release
# run, not here.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export SCRATCH=$scratch

mkdir "$scratch/bin"
for tool in security xcrun base64 spctl gh make hdiutil codesign sleep; do
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
  "security find-identity -v")
    [ ! -e "$SCRATCH/no-identity" ] || { echo "     0 valid identities found"; exit 0; }
    echo '  1) ABC123 "Developer ID Application: Brandon Fryslie (6R988MUU27)"' ;;
  "gh api "*) cat "$SCRATCH/tag-commit" ;;
  "make --no-print-directory release") echo "$SCRATCH/built/OrangeDrink.app" ;;
  "make --no-print-directory sparkle-tools") echo "$SCRATCH/sparkle-tools" ;;
  "hdiutil create "*)
    fails=$(cat "$SCRATCH/hdiutil-fails")
    if [ "$fails" -gt 0 ]; then echo $((fails - 1)) >"$SCRATCH/hdiutil-fails"; echo "hdiutil: create failed - Resource busy" >&2; exit 1; fi
    touch "${!#}" ;;
esac
exit 0
STUB
  chmod +x "$scratch/bin/$tool"
done
export PATH="$scratch/bin:$PATH"
# generate_appcast, which scripts/appcast finds through `make sparkle-tools`: records its arguments, the key it was
# given and the directory's files, and writes the feed $SCRATCH/feed-body holds.
mkdir "$scratch/sparkle-tools"
cat > "$scratch/sparkle-tools/generate_appcast" <<'STUB'
#!/bin/bash
echo "generate_appcast $*" >>"$SCRATCH/calls"
cat >"$SCRATCH/key-seen"
ls "${!#}" >"$SCRATCH/images-seen"
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then cp "$SCRATCH/feed-body" "$2"; fi
  shift
done
STUB
chmod +x "$scratch/sparkle-tools/generate_appcast"
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
     "$repo/scripts/release-publish" "$repo/scripts/notarize" "$repo/scripts/dmg" "$repo/scripts/developer-id" \
     "$repo/scripts/appcast" "$dir/scripts/"
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
calls_reset; secrets; touch "$scratch/no-identity"
expect "a .p12 without the Developer ID identity fails, naming it" 1 'gave no valid "Developer ID Application: Brandon Fryslie (6R988MUU27)"' -- "$t/scripts/release-keychain"
rm -f "$scratch/no-identity"
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
  "security find-identity -v -p codesigning $k"
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

# --- scripts/dmg: hdiutil create fails now and then on hosted runners
t=$(tree 'MARKETING_VERSION: "1.2.3"')
mkdir -p "$scratch/built/OrangeDrink.app/Contents"
cat >"$scratch/built/OrangeDrink.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.2.3</string></dict></plist>
PLIST
echo '{"status":"Accepted","id":"sub-3"}' >"$scratch/submit.json"
echo 2 >"$scratch/hdiutil-fails"
expect "an hdiutil create that fails twice is tried again and the image is made" 0 "$scratch/out/OrangeDrink-1.2.3.dmg" -- "$t/scripts/dmg" "$scratch/out"
echo 99 >"$scratch/hdiutil-fails"
expect "an hdiutil create that keeps failing stops the build, saying so" 1 "hdiutil create failed 5 times" -- "$t/scripts/dmg" "$scratch/out"

# --- scripts/release-publish: a release goes out only for the commit the tag still names
t=$(tree 'MARKETING_VERSION: "1.2.3"')
export GITHUB_REPOSITORY=promptctl/orange-drink GITHUB_SHA=built-commit
echo built-commit >"$scratch/tag-commit"
calls_reset
expect "the release is made while the tag names the commit that was built" 0 "" -- "$t/scripts/release-publish" v1.2.3 "$scratch/image.dmg" "$scratch/appcast.xml"
called "gh api repos/promptctl/orange-drink/commits/tags/v1.2.3 --jq .sha" && called "gh release create v1.2.3 $scratch/image.dmg $scratch/appcast.xml --verify-tag --title Orange Drink 1.2.3 --generate-notes" \
  && pass "it reads the tag's commit, then publishes under the tag's version" || fail "it reads the tag's commit, then publishes under the tag's version: $(cat "$scratch/calls")"
echo moved-commit >"$scratch/tag-commit"
calls_reset
expect "a tag that moved stops the release, naming both commits" 1 "tag v1.2.3 now names moved-commit, and this run built built-commit" -- "$t/scripts/release-publish" v1.2.3 "$scratch/image.dmg" "$scratch/appcast.xml"
called "gh release create" && fail "a moved tag was released" || pass "a moved tag makes no release"

# --- scripts/appcast: a feed that installed copies would refuse never leaves here
t=$(tree 'MARKETING_VERSION: "1.2.3"')
mkdir "$scratch/dist"
touch "$scratch/dist/OrangeDrink-1.2.3.dmg" "$scratch/dist/OrangeDrink-1.2.2.dmg"
prefix=https://github.com/promptctl/orange-drink/releases/download/v1.2.3/
feed() { printf the-private-key | "$t/scripts/appcast" "$scratch/dist/OrangeDrink-1.2.3.dmg" "$prefix"; }
echo '<enclosure url="x" sparkle:edSignature="c2ln" length="1"/>' >"$scratch/feed-body"
calls_reset
expect "a signed feed is written beside its image, and its path printed" 0 "$scratch/dist/appcast.xml" -- feed
grep -q 'edSignature="c2ln"' "$scratch/dist/appcast.xml" && pass "the feed is the one generate_appcast wrote" || fail "the feed is the one generate_appcast wrote"
[ "$(cat "$scratch/key-seen")" = the-private-key ] && pass "generate_appcast reads the key from stdin" || fail "generate_appcast reads the key from stdin: $(cat "$scratch/key-seen")"
called "generate_appcast --ed-key-file - --download-url-prefix $prefix -o " && pass "the key is on no command line, and the prefix is passed" || fail "the key is on no command line, and the prefix is passed: $(cat "$scratch/calls")"
[ "$(cat "$scratch/images-seen")" = OrangeDrink-1.2.3.dmg ] && pass "generate_appcast sees this image alone, so it makes no deltas" || fail "generate_appcast sees this image alone: $(cat "$scratch/images-seen")"
rm "$scratch/dist/appcast.xml"
echo '<enclosure url="x" length="1"/>' >"$scratch/feed-body"
expect "a feed with no signature is refused, saying what to look at" 1 "has no EdDSA signature" -- feed
[ ! -e "$scratch/dist/appcast.xml" ] && pass "a refused feed leaves nothing to publish" || fail "a refused feed leaves nothing to publish"

exit $failed
