# Pausing charging through the SMC

The helper pauses charging by writing one SMC key, `CHTE`, as root. This page is what that rests on and where it
stops. The code is `Sources/HelperInterface/ChargingPause.swift`. The measurements come from the spike
orange-admin-helper-b2q.16g, run on one Mac: an Apple M4 Max on macOS 26.5.2 (25F84). Nothing here was measured on
another chip or another macOS release. Two sources carry the numbers: `spikes/orange-admin-helper-b2q.16g/output.txt`
(the committed run) and the ticket's comments (`lit show orange-admin-helper-b2q.16g`), which hold a live check of the
shipped helper. Each section below says which one it rests on.

## The key

`CHTE` is a `ui32`, four bytes. `01000000` pauses charging and `00000000` lets it run. The SMC on that Mac also listed
`CHIE` and `bfD0`, and had no `bfF0`, `bfE0`, `CH0B` or `CH0C`. Nothing wrote any key but `CHTE`. Third-party notes
(macwake) say `CHIE` cuts the adapter, which discharges the battery rather than pausing it; that was not checked here.

`ChargeInhibitKey` asks the SMC for the key's type and size once per opening and treats anything but a four-byte
`ui32` as a Mac it cannot pause. A Mac without `CHTE` would fail that first `keyInfo` call; the code reads SMC result
`0x84` as key not found. No Mac without `CHTE` was available, so that path was never run. The spike saw `0x85` on
`CHHV` and `CHHW`.

## Who may write it

Only root. The same write from an unprivileged process returned `kIOReturnNotPrivileged` (`0xe00002c1`) and left the
key at its old value. That is why the write lives in the helper and not the app.

## Confirming a pause from outside the writer

The writer exits before anything else can look, so the pause is read from the battery registry and the key:

- `NotChargingReason` in `AppleSmartBattery`'s `ChargerData` has bit 55 (`0x80000000000000`) set while `CHTE` holds a
  pause. Bit 24 (`0x1000000`) is macOS's own Charge Limit. Both are set when both hold.
- The SMC's `CHNC` gains `0x8000` the moment `CHTE` is written.
- `IsCharging` goes to 0 and `ChargingCurrent` to 0. The registry trails the write: in `output.txt` `CHNC` changed by
  12:00:16 and `IsCharging` reached 0 by 12:00:26, so 10 to 15 seconds; the live check on the ticket saw about 25.
  Charging came back about 30 seconds after writing `00000000` in both.

## What a held pause survives

All of these were observed with `CHTE` at `01000000` throughout, and `NotChargingReason` bit 55 still set after each.
The first three are in `output.txt`; the Charge Limit toggle is only in the ticket's live check (the committed run
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

## Reading the key by hand

The spike's `smc.swift` is a small command-line client for the AppleSMC user client (`list`, `read KEY`, `write KEY HEX`
and `observe`, which prints the registry fields above beside `CHNC`). `list` and `read` need no root. No binary is
committed; build one from the source:

    swiftc -O spikes/orange-admin-helper-b2q.16g/smc.swift -o /tmp/smc
    sudo /tmp/smc write CHTE 00000000    # resumes charging if a run left the Mac paused

Once the spike folder is deleted from the tree, the source and `output.txt` stay in git history:
`git log --oneline -- spikes/orange-admin-helper-b2q.16g` finds the last commit that has them.
