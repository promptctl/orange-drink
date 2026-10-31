# Releasing

Pushing the tag `v<version>` publishes that version's notarized DMG as a GitHub release
(`.github/workflows/release.yaml`). `<version>` is `project.yml`'s `MARKETING_VERSION`.

## Cut a release

1. Raise `MARKETING_VERSION` in a PR and merge it.
2. `git fetch origin && git tag v<version> origin/master && git push origin v<version>`
3. Check that the run's commit is on master, then approve it when GitHub asks: the `release` environment holds the
   signing secrets and has a required reviewer. `git fetch origin && git merge-base --is-ancestor <commit> origin/master`
   exits 0 for a commit on master.

The `preflight` job runs first, with no approval. It fails a tag that is not `v<MARKETING_VERSION>` or whose
commit is not on master (`scripts/release-preflight`), so a bad tag is read from a failed run
(`gh run view <id> --log-failed`) and is never put up for approval. Delete a bad tag with
`git push origin :refs/tags/<tag>`. A tag with a release already made fails at `gh release create`; it never
replaces one.

A tag runs the workflow in its own commit, so a commit off master can carry a copy with `preflight` removed, and
that copy still asks for the same approval. The approval is what protects the Developer ID key, which is why step 3
checks the commit.

## The `release` environment's secrets

Set each with `gh secret set <NAME> --env release -R promptctl/orange-drink`.

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12` | The Developer ID Application identity (team 6R988MUU27), exported from Keychain Access as a .p12 and base64-encoded: `base64 -i identity.p12 \| gh secret set DEVELOPER_ID_APPLICATION_P12 --env release` |
| `DEVELOPER_ID_P12_PASSWORD` | The password chosen at export |
| `NOTARY_APPLE_ID` | The Apple ID that notarizes |
| `NOTARY_PASSWORD` | An app-specific password for it, made at account.apple.com |

`scripts/release-keychain` turns these into the job's keychain, and refuses to run anywhere but a GitHub-hosted runner.
