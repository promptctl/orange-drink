# Pausing charging through the SMC

The helper pauses charging by writing one SMC key, `CHTE`, as root. This page is what that rests on and where it
stops. The code is `Sources/HelperInterface/ChargingPause.swift`. The measurements come from the spike
orange-admin-helper-b2q.16g, run on one Mac: an Apple M4 Max on macOS 26.5.2 (25F84). Nothing here was measured on
another chip or another macOS release. Two sources carry the numbers: `docs/smc-charging-output.txt`
(the spike's committed run, with one line edited: the absolute path in run.sh's "manual restore" hint is cut to `smc`)
and the ticket's comments (`lit show orange-admin-helper-b2q.16g`), which hold a live check of the shipped helper. Each section below says which one it rests on.

## The key

`CHTE` is a `ui32`, four bytes. `01000000` pauses charging and `00000000` lets it run. The SMC on that Mac also listed
`CHIE` and `bfD0`; the key list in `smc-charging-output.txt` has no `bfF0`, `bfE0`, `CH0B` or `CH0C`. Nothing wrote any key but `CHTE`. Third-party notes
(macwake) say `CHIE` cuts the adapter, which discharges the battery rather than pausing it; that was not checked here.

`ChargeInhibitKey` asks the SMC for the key's type and size once per opening and treats anything but a four-byte
`ui32` as a Mac it cannot pause. A Mac without `CHTE` would fail that first `keyInfo` call; the code reads SMC result
`0x84` as key not found. No Mac without `CHTE` was available, so that path was never run and `0x84` is unconfirmed.

## Who may write it

Only root. The same write from an unprivileged process returned `kIOReturnNotPrivileged` (`0xe00002c1`) and left the
key at its old value. That is why the write lives in the helper and not the app.

## Confirming a pause from outside the writer

The writer exits before anything else can look, so the pause is read from the battery registry and the key:

- `NotChargingReason` in `AppleSmartBattery`'s `ChargerData` has bit 55 (`0x80000000000000`) set while `CHTE` holds a
  pause. Bit 24 (`0x1000000`) is macOS's own Charge Limit. The ticket's live check saw both set when both held; `smc-charging-output.txt`
  only ever shows bit 55 alone.
- The SMC's `CHNC` gains `0x8000` the moment `CHTE` is written.
- `IsCharging` goes to 0 and `ChargingCurrent` to 0. The registry trails the write. `smc-charging-output.txt` samples every 5 seconds
  and does not record the write itself: `CHNC` had changed by 12:00:16 and `IsCharging` reached 0 by 12:00:26. The live
  check on the ticket saw about 25 seconds. Size any wait from the 25. Charging came back about 30 seconds after writing
  `00000000`, on the ticket's live check and in `smc-charging-output.txt` (12:04:33 to 12:05:03).

## What a held pause survives

All of these were observed with `CHTE` at `01000000` throughout, and `NotChargingReason` bit 55 still set after each.
The first three are in `smc-charging-output.txt`; the Charge Limit toggle is only in the ticket's live check (the committed run
never moved the limit):

- The writer exiting. The key is SMC state; it outlives whoever wrote it, so nothing but another write ends the pause.
  This is why the helper keeps a marker and writes `00000000` back on its way out (`ChargingStep.mark` and `.unmark`).
- Unplugging and replugging the charger.
- Sleep and wake.
- Charge Limit turned off and on again in System Settings (ticket comment `cmt-abc74a3f`). powerd did not touch the
  pause in the 60 seconds after each change, though lifting the limit did clear bit 24 and stop its adapter drain.

## Not observed

- Whether powerd or Optimized Charging overrides a pause when the battery crosses the Charge Limit's level while
  paused. The runs started below the limit and never reached it.
- Optimized Charging's learned hold.
- Any chip other than the M4 Max, and any macOS other than 26.5.2.
- Charge Limit's slider is a trap when testing: stepping it up past 95 saves 95 as the level "Allow Until Tomorrow"
  returns to. Set it back by hand after any test.

## The Charge Limit's own level cannot be read

macOS publishes no number for the Charge Limit a person set (checked on macOS 26.5.2 with the limit at 80%, spike
orange-alerts-cjt.c2g, whose probe and README are in git at `af7ee2c`). `PowerUISmartChargeClient`, which System Settings uses, answers an unentitled caller with no
available limits and a limit of 100, and no IOPS, registry, SMC or preference key holds it. What the app can see is that
a limit is in force: bit 24 of `NotChargingReason` is set from the moment the percent reaches the limit, while IOPS still
says charging with a time to full that counts to 100% (`Sources/OrangeDrink/Battery/BatteryReading.swift` reads the bit).

## The spike's SMC client

The measurements above were taken with a throwaway command-line client for the AppleSMC user client (`list`, `read KEY`,
`write KEY HEX`, and `observe`, which prints the registry fields beside `CHNC`). It is not in the tree: the app's own
client is `ChargingPause.swift`. Its source, the spike's run script and the rest of the folder are in git at `af7ee2c`
(`git ls-tree -r --name-only af7ee2c | grep b2q.16g`).

## A Mac left paused

The helper gives charging back itself: when no connection holds a pause and its marker file exists,
`ChargingInhibit.reconcile` writes `00000000` and clears the marker. That runs as the helper exits and again at its next
start, because the marker outlives a helper that was killed. So a SIGKILL, a crash or a power loss leaves the Mac paused
until the helper next starts, and a helper that never starts again (unregistered, say) leaves it paused for good. That
case has no tool in the tree; the spike's client at `af7ee2c`, built and run as root with `write CHTE 00000000`, ends it.
That command was run in the spike on the Mac named at the top.
