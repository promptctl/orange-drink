# orange-admin-helper-b2q.16g: pausing and resuming charging through the SMC

Apple M4 Max, macOS 26.5.2 (25F84), with macOS's own Charge Limit on at 80%.

- `smc.swift`: the AppleSMC user client from user space. `smc list` is read-only and needs no root. `smc observe`
  prints one line, the battery registry's charging state beside the SMC's CHNC, which is how charging is confirmed from
  outside the process that wrote the key.
- `run.sh`: run once in Terminal, at the Mac, plugged in: `sudo ./run.sh`. It reads the pause key's bytes before
  writing anything, tries the write without root, pauses, and asks for an unplug and replug and for Charge Limit to be
  toggled off and on (press Return after each), sleeping and waking the Mac itself in between. Then it writes the bytes back. An exit trap restores
  the key on any exit the shell sees. `output.txt` holds the run, and `powerd.log` holds powerd's and PowerUIAgent's log.

If the run dies where no trap fires (SIGKILL, a crash, power loss), restore the key by hand to the baseline `run.sh`
printed. As read before any run, that was:

```
sudo spikes/orange-admin-helper-b2q.16g/build/smc write CHTE 00000000
```
