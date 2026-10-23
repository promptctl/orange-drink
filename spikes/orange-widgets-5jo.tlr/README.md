# orange-widgets-5jo.tlr: a widget for an unsandboxed, Developer ID-signed app

A menu-bar-only host app (`Host/`) writes a level into a team-prefixed app-group container and asks
WidgetKit to reload. Its sandboxed widget (`Widget/`) reads the level and draws `SEQ n` and the
percent, or the read error. `project.yml` signs both the way the app's own project.yml and
`make release` do.

Run in this order. The first step runs on a Mac holding the Developer ID identity; the rest run on the Mac under test.

1. `./run.sh ship release HOST` (or `debug`): builds the variant, copies it and these scripts to
   `HOST:/tmp/orange-widgets-5jo.tlr/`, and installs it in /Applications there. It prints both
   bundles' signing and entitlements, Gatekeeper's verdict, and the pluginkit registration.
2. On HOST: right-click a placed widget or the desktop, choose Edit Widgets…, and search for
   OrangeWidgetSpike. Then drag it onto the desktop.
3. On HOST: `measure.sh EVERY TIMES FROM RECT` runs a reload schedule and prints, with times, each
   sequence the placed widget shows. To set the screen beside the reloads, stream the log:
   `/usr/bin/log stream --style compact --level info --predicate 'subsystem == "dev.orangedrink.widgetspike"'`.
4. On HOST: remove the widget from the desktop, then `run.sh uninstall`.

`output.txt` holds the runs behind the finding on the ticket.
