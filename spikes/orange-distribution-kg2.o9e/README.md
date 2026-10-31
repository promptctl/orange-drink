# orange-distribution-kg2.o9e: recognising and closing macOS's low battery notification

- `banners.swift`: reads NotificationCenter's accessibility tree, says which notification is the system's low battery one, and closes it. Its modes are listed at the top of the file.
- `fake-battery.swift`: raises the warning on a VM, which has no battery. It publishes a stand-in power source to powerd and writes the warning level where powerd publishes it. ControlCenter's own code then posts the real notification. Run it only in a VM.
- `proof.sh`: the steps, run inside a VM by `run.sh`.
- `run.sh`: `./run.sh <tart image>...` runs `proof.sh` in a throwaway VM of each image and replaces `output.txt`. A step that fails stops the run and records nothing. Nothing shows on the Mac running it.
- `output.txt`: macOS 26.6.2, 15.7.7, and 14.8.7, from `./run.sh orange-drink-xcode ghcr.io/cirruslabs/macos-sequoia-base:latest ghcr.io/cirruslabs/macos-sonoma-base:latest`.

The finding is on the ticket.

Traps in the VM runs:

- A VM's shared directory serves the first copy of a file it read, so a rebuilt binary at the same path runs the old one. `run.sh` uses a new directory each run.
- Script Editor shows no banner on macOS 15 and 26 until it is allowed, and `proof.sh` sets that flag in `com.apple.ncprefs`. It goes through `defaults export` and `import`, because the plist on disk lags cfprefsd.
- On macOS 26 the battery notification takes over the top-right corner from a banner already showing, so `proof.sh` raises it first and the other app's a second later.
