# orange-admin-helper-b2q.0at: a privileged helper that accepts only its app

`HelperSpike.app` (`App/`) registers `HelperSpikeHelper` (`Helper/`) as a launchd daemon with
`SMAppService.daemon(plistName:)`, from the plist in `App/`. When it launches, the helper reads its app's designated
requirement off the app's signature: `cdhash H"…"` for an ad-hoc app, or identifier and team for a Developer ID app. It
enforces that requirement with `NSXPCListener.setConnectionCodeSigningRequirement`. Its one call, `whoAmI`, answers
with its own pid, euid and cdhash, the requirement, and the caller's signature. `Impostor` (`Impostor/`) is different
code, which `run.sh` signs ad hoc with the app's identifier. The two variants, `adhoc` (master's `make build`) and
`devid` (PR #11's `make build`), differ only in the signer.

Run in this order. The first step runs on a Mac that holds the Developer ID identity, and the rest run on the Mac under test.

1. `./run.sh ship adhoc|devid VERSION HOST DIR` (or `build`, then `place` on the same Mac). This places the app in `DIR` and
   prints the signatures and designated requirements of the app, the helper and the impostor.
2. `run.sh register`, then `run.sh status`. Approve HelperSpike under System Settings › General › Login Items &
   Extensions › Allow in the Background, then run `status` again.
3. `run.sh call`, then `run.sh impostor`, then `run.sh call`.
4. Rebuild by re-running step 1 with the next VERSION and the same `DIR`, then `run.sh status` and `run.sh call`.
5. `run.sh uninstall`.

Where nobody can approve, `run.sh bootstrap` loads the same helper with launchd the legacy way, and step 3 still
runs. `run.sh bootout` unloads it. `output.txt` holds the runs behind the finding on the ticket.
