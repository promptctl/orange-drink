# Spike orange-distribution-kg2.73n

Where can IOBluetooth be registered without holding the main thread on the Bluetooth permission prompt?

- `spike.swift` and `run.sh`: one app per variant, each with its own bundle id so each meets the prompt with its own TCC entry, in one fresh VM. A main-thread timer writes a heartbeat beside what the variant did. `output.txt` holds the runs. The Don't Allow run pressed that button in place of Allow in `FirstLaunchUITests`.
- `real-mac.swift`: the variants on a Mac with devices connected. It stops unless the permission is already allowed, so it cannot raise a prompt.

| Variant | Main thread with the prompt open | Registers | Later connects |
|---|---|---|---|
| main | held, no heartbeat until the answer | yes, after the answer | proven: the shipping path |
| pool thread | free | yes, after the answer | not shown |
| dedicated thread with a run loop | free | yes, after the answer | not shown |
| `CBCentralManager`, then main | free | yes, 0.1 s after the answer | proven: registration is the shipping path |

Both off-main variants heard the replayed connects on a real Mac, but those arrive inside the registering call. Only a device connecting later would prove delivery, a VM has no devices, and e72e0b1 moved registration to main because a pool thread was refused.

The answer is the same TCC service for both frameworks: after `CBCentralManager`'s prompt, IOBluetooth neither waits nor asks again. On Don't Allow the state is unauthorized, the authorization denied, and a registration returns with no devices. A rebuild, the same bundle id with a new ad-hoc signature after Allow, reads not determined, not a stale allowed, so the main thread stays free for the Debug builds the ticket found this on. With the permission already allowed, the first delegate call came 124 ms after init on a real Mac, state poweredOn. Apple documents that a manager warns the person when Bluetooth is off unless `CBCentralManagerOptionShowPowerAlertKey` is false; that was not measured here.
