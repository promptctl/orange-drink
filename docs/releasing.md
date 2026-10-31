# Releasing

Pushing the tag `v<version>` publishes that version's notarized DMG as a GitHub release, with the update feed
that offers it (`.github/workflows/release.yaml`). `<version>` is `project.yml`'s `MARKETING_VERSION`.

Installed copies read that feed through `SUFeedURL`, `releases/latest/download/appcast.xml`, when the panel's
Check for Updates… row is pressed. The release marked latest is the update every older copy is offered.

## Cut a release

1. Raise `MARKETING_VERSION` in a PR and merge it. The build number follows it.
2. Run `make test` on that commit. The release workflow does not run the tests.
3. `git fetch origin && git tag v<version> origin/master && git push origin v<version>`
4. Check that the run's commit is on master, then approve it when GitHub asks: the `release` environment holds the
   signing secrets and has a required reviewer. `git fetch origin && git merge-base --is-ancestor <commit> origin/master`
   exits 0 for a commit on master.

The `preflight` job runs first, with no approval. It fails a tag that is not `v<MARKETING_VERSION>` or whose
commit is not on master (`scripts/release-preflight`), so a bad tag is read from a failed run
(`gh run view <id> --log-failed`) and is never put up for approval. Delete a bad tag with
`git push origin :refs/tags/<tag>`. A tag with a release already made fails at `gh release create`; it never
replaces one. A tag moved after its run began fails that run at publishing (`scripts/release-publish`), so a
release never pairs one commit's DMG with another commit's tag.

A tag runs the workflow in its own commit, so a commit off master can carry a copy with `preflight` removed, and
that copy still asks for the same approval. The approval is what protects the Developer ID key, which is why step 4
checks the commit.

## The `release` environment's secrets

Set each with `gh secret set <NAME> --env release -R promptctl/orange-drink`.

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12` | The Developer ID Application identity (team 6R988MUU27), exported from Keychain Access as a .p12 and base64-encoded: `base64 -i identity.p12 \| gh secret set DEVELOPER_ID_APPLICATION_P12 --env release` |
| `DEVELOPER_ID_P12_PASSWORD` | The password chosen at export |
| `NOTARY_APPLE_ID` | The Apple ID that notarizes |
| `NOTARY_PASSWORD` | An app-specific password for it, made at account.apple.com |
| `SPARKLE_ED_KEY` | The EdDSA private key that signs updates (below) |

`scripts/release-keychain` turns these into the job's keychain, and refuses to run anywhere but a GitHub-hosted runner.

## The update signing key

An installed copy accepts only an update signed by the private half of `SUPublicEDKey` in `project.yml`. It is in
the login keychain of the Mac it was made on, under Sparkle's account `orange-drink`, and in the `SPARKLE_ED_KEY`
secret, which GitHub never shows again. `make update-check` signs its feeds with the keychain copy, and a new secret
is made from it, so losing it costs those two; losing both means no installed copy can be updated: a new key reaches
only copies installed after it ships.

Sparkle's tools are in the directory `make --no-print-directory sparkle-tools | tail -n 1` prints. To set the
secret again, or to copy the key to another Mac with `generate_keys --account orange-drink -f <file>`:

    generate_keys --account orange-drink -x key
    gh secret set SPARKLE_ED_KEY --env release -R promptctl/orange-drink <key
    rm key
