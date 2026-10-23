#!/bin/bash
# [LAW:behavior-not-structure] scripts/hardware-check.swift seen from outside: each case runs it in a scratch git
# repository whose branch is a ticket id, with lit and xcrun stood in on PATH (the script reaches every tool through
# /usr/bin/env), and asserts what it prints, what it posts, and how it exits.
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/hardware-check.swift
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -o "$scratch/hardware-check" "$script"

# lit: one ticket, ticket-1. Each post lands in $SCRATCH/posted as the next number; export prints $SCRATCH/export.json;
# a file at $SCRATCH/lit-down makes posting fail.
mkdir "$scratch/bin" "$scratch/posted"
cat > "$scratch/bin/lit" <<'STUB'
#!/bin/bash
case "$1" in
  show) [ "$2" = ticket-1 ] || { echo "error (code=4, reason=entity_not_found): issue \"$2\" not found" >&2; exit 4; }; echo ticket-1 ;;
  export) cat "$SCRATCH/export.json" ;;
  comment) [ "$3" = ticket-1 ] && [ ! -e "$SCRATCH/lit-down" ] || exit 1; cp "$7" "$SCRATCH/posted/$(ls "$SCRATCH/posted" | wc -l | tr -d ' ')" ;;
  *) echo "lit stand-in: unexpected $*" >&2; exit 2 ;;
esac
STUB
# xcrun xcresulttool get test-results tests --path <bundle>: the bundle's tests.json.
cat > "$scratch/bin/xcrun" <<'STUB'
#!/bin/bash
cat "$6/tests.json"
STUB
chmod +x "$scratch/bin/lit" "$scratch/bin/xcrun"
export PATH="$scratch/bin:$PATH" SCRATCH="$scratch"

mkdir "$scratch/repo" && cd "$scratch/repo"
git init -q -b ticket-1 && git config user.email check@example.com && git config user.name check
mkdir src && echo a > src/a.swift && echo b > src/b.swift && git add src && git commit -qm one

failures=0
expect() { # <what> <command...>: one assertion, reported either way
  if "${@:2}"; then echo "ok: $1"; else echo "FAIL: $1"; echo "$out" | sed 's/^/    /'; failures=$((failures + 1)); fi
}
# The recorder with stdin from $answers (default none); sets out and status.
recorder() { status=0; out=$(printf '%b' "${answers:-}" | "$scratch/hardware-check" "$@" 2>&1) || status=$?; }
# A result bundle whose one test, Suite/check(), ended as $1, with failure messages $2...
bundle() {
  local children=$(printf '{"nodeType":"Failure Message","name":"%s"},' "${@:2}")
  [ $# -gt 1 ] || children=
  rm -rf build/c.xcresult && mkdir -p build/c.xcresult
  printf '{"testNodes":[{"nodeType":"Test Case","name":"check()","nodeIdentifier":"Suite/check()","result":"%s","children":[%s]}]}' \
    "$1" "${children%,}" > build/c.xcresult/tests.json
}
run() { recorder run c --test 'Suite/check()' --bundle build/c.xcresult "$@"; }
posts() { ls "$scratch/posted" | wc -l | tr -d ' '; }
latest() { cat "$scratch/posted/$(($(posts) - 1))"; }
has() { grep -qxF -- "$1" <<<"$2"; }
# export.json holding comments <id> <body>..., oldest first, on ticket-1
comments() {
  python3 -c 'import json, sys; a = sys.argv[1:]; print(json.dumps({"comments": [{"id": a[i], "issue_id": "ticket-1", "body": a[i + 1], "created_at": f"2026-10-22T00:00:{i // 2:02d}.5Z"} for i in range(0, len(a), 2)]}))' "$@" > "$scratch/export.json"
}
status_of() { recorder status --check c "$@"; }

# run

git checkout -qb not-a-ticket
bundle Passed
run --covers src -- true
expect "a branch that names no ticket stops before the test, saying so" \
  eval '[ $status = 1 ] && grep -qF "the branch not-a-ticket names no lit ticket" <<<"$out" && [ $(posts) = 0 ]'
git checkout -q ticket-1

bundle Passed
answers='y\n' run --covers src/a.swift src --ask 'Saw it?' -- sh -c 'echo "» reading 5"; echo "not for the record"'
body=$(latest)
expect "a pass posts its result, commit, covers, printed lines, and answers, and exits 0" \
  eval '[ $status = 0 ] && has "hardware check: c" "$body" && has "result: pass" "$body" && has "commit: $(git rev-parse HEAD)" "$body" &&
        has "covers: $(git rev-parse HEAD:src/a.swift) src/a.swift" "$body" && has "covers: $(git rev-parse HEAD:src) src" "$body" &&
        has "printed: reading 5" "$body" && has "asked: Saw it? → y" "$body" && ! grep -q "^uncommitted:" <<<"$body" &&
        ! grep -qF "not for the record" <<<"$body"'

echo new > src/new.swift
bundle Passed
run --covers src/new.swift src -- true
body=$(latest)
expect "a covered file new on disk is run and recorded as uncommitted" \
  eval '[ $status = 0 ] && has "uncommitted: src/new.swift" "$body" && has "uncommitted: src" "$body" &&
        has "covers: $(git hash-object src/new.swift) src/new.swift" "$body"'
rm src/new.swift

mv src/b.swift "$scratch/b.swift"
before=$(posts)
run --covers src/b.swift -- true
expect "a covered file missing from disk stops the run before the test, naming it" \
  eval '[ $status = 1 ] && grep -qF "the covered path src/b.swift is not on disk" <<<"$out" && [ $(posts) = $before ]'
mv "$scratch/b.swift" src/b.swift

bundle Skipped
before=$(posts)
run --covers src -- true
expect "a skipped test posts nothing and exits 1" \
  eval '[ $status = 1 ] && grep -qF "was skipped" <<<"$out" && [ $(posts) = $before ]'

bundle Failed 'check.swift:3: expectation failed'
run --covers src -- true
body=$(latest)
expect "a failed test posts fail with its failure and exits 1" \
  eval '[ $status = 1 ] && has "result: fail" "$body" && has "failure: check.swift:3: expectation failed" "$body"'

bundle Passed
run --covers src -- sh -c 'exit 3'
body=$(latest)
expect "a passing test under a failing command posts fail, naming the exit" \
  eval '[ $status = 1 ] && has "result: fail" "$body" && has "failure: sh exited 3" "$body"'

touch "$scratch/lit-down"
bundle Passed
before=$(posts)
answers='y\n' run --covers src --ask 'Saw it?' -- true
expect "a failed post keeps the record on disk and names the command that posts it" \
  eval '[ $status = 1 ] && [ $(posts) = $before ] && has "asked: Saw it? → y" "$(cat build/c.record)" &&
        grep -qF -- "--body-file build/c.record exited 1" <<<"$out"'
rm "$scratch/lit-down"

# status

src=$(git rev-parse HEAD:src)
comments
status_of src
expect "no record is never run" eval '[ $status = 0 ] && grep -qF "c: never run" <<<"$out"'

comments n1 'ran c by hand, it passed' r1 $'hardware check: c\nresult: pass\ncommit: 1234567890\ncovers: '"$src"' src'
status_of src
expect "a record whose covers match HEAD stands; a hand note is not a record" \
  eval '[ $status = 0 ] && grep -qF "c: stands (pass, 1234567)" <<<"$out"'

comments r1 $'hardware check: c\nresult: pass\ncommit: 1234567890\ncovers: '"$src"' src' \
  r2 $'hardware check: c\nresult: fail\ncommit: abcdef0123\ncovers: '"$src"$' src\nfailure: no iPhone is cabled'
status_of src
expect "the latest record stands, and a standing fail shows its failures" \
  eval '[ $status = 0 ] && grep -qF "c: stands (fail, abcdef0)" <<<"$out" && grep -qF "    failure: no iPhone is cabled" <<<"$out"'

comments r1 $'hardware check: c\nresult: pass\ncommit: 1234567890\ncovers: '"$src"$' src\ncovers: 0123abcd src/gone.swift'
status_of src src/gone.swift
expect "a covered path HEAD does not hold is stale, and the report goes on" \
  eval '[ $status = 0 ] && grep -qF "c: stale: src/gone.swift" <<<"$out"'

comments r1 $'hardware check: c\nresult: pass\ncommit: 1234567890\ncovers: '"$src"' src'
status_of src src/gone.swift
expect "a path declared since the record, absent at HEAD too, is stale" \
  eval '[ $status = 0 ] && grep -qF "c: stale: src/gone.swift" <<<"$out"'

echo changed > src/a.swift && git commit -qam two
status_of src
expect "a record whose covered code changed at HEAD is stale, naming the path" \
  eval '[ $status = 0 ] && grep -qF "c: stale: src" <<<"$out"'

comments r1 $'hardware check: c\nresult: maybe\ncommit: 1234567890\ncovers: '"$src"' src'
status_of src
expect "a record that does not parse fails status, naming the comment" \
  eval '[ $status = 1 ] && grep -qF "comment r1 starts as a hardware check record but has no result" <<<"$out"'

[ $failures = 0 ] || { echo "$failures hardware-check case(s) failed"; exit 1; }
