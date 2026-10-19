# Spike orange-settings-7du.s4n

Do real key presses reach the panel's single-key shortcuts through an AppKit local monitor while the panel is open? `./run.sh` opens a minimal `MenuBarExtra` panel with a posted ⌃⌥J, types i, i, d, d, x with `CGEvent`, and prints the sections' state after each. `output.txt` is the last run. The app itself is never launched.
