# Spike orange-history-4y3.qvj

How can the app measure per-app energy without a public API? `./run.sh` samples one 20-second window with `proc_pid_rusage` energy counters (`rusage.swift`), with `top -stats power`, and with Activity Monitor's Energy tab read through the accessibility tree (`activity-monitor.applescript`), and prints each one's leaders and CPU cost. `output.txt` is the last run.
