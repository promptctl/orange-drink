# Alerts

Turns notifications on or off, and holds the list of alerts: low-battery thresholds, charged thresholds, and power-source events. Each threshold alert has its own position on screen, glow, and sound.

**Header:** green tile with a white bell, title "Alerts".
**Subtitle:** "Configure battery notifications and visual effects"
**Background:** soft green glow at the top right and a faint red glow in the middle, behind the low-battery list.

## General

Section icon: grey outlined gear.

One card with one row:

- Blue bell tile.
- Title "Enable Notifications", description "Show battery alerts and notifications".
- Switch, on (green). The master switch for every alert on this screen.

## Low Battery Alerts

Section icon: red battery outline, nearly empty.
Info line: "ⓘ Notify when battery goes below percentage"

A stack of separate cards, one per alert, sorted from lowest threshold to highest. Each card holds:

- **On the left:** a battery outline icon with a sliver of fill, coloured by severity.
- **Percentage chip:** a small rounded rectangle tinted with the severity colour, holding the threshold in bold white, such as "3%".
- **Summary line:** under the chip, grey text listing the alert's options joined by " • ".
- **On the right, two circular buttons:**
  - A grey gear opens that alert's editor. The editor itself isn't shown in the reference.
  - A red trash can deletes the alert.

Reference contents:

| Threshold | Colour | Summary |
| --- | --- | --- |
| 3% | red | Center of Screen • Border Glow • Sound |
| 5% | red | Center of Screen • Sound |
| 15% | yellow | Top of Screen |

So each alert has these options:
- **Position:** "Center of Screen" or "Top of Screen".
- **Border Glow:** on or off. This is the screen edge glow.
- **Sound:** on or off. The summary lists only the options that are on.

The reference colours red at 5% and below and yellow at 15%. Severity is presumably assigned by threshold band.

Under the stack is a centred, dark, rounded button: "＋ Add Low Battery Alert".

## Charged Alerts

Section icon: green battery with a lightning bolt.
Info line: "ⓘ Notify when battery reaches percentage"

Same card layout as low-battery alerts, in green:

| Threshold | Colour | Summary |
| --- | --- | --- |
| 80% | green (charging-battery icon) | Top of Screen • Sound |

Under it is a centred button: "＋ Add Charged Alert".

## Power Source Alerts

Section icon: orange plug.

One card with a row:

- Yellow lightning-bolt tile.
- Title "Plugged In", description "Notify when power adapter is connected".
- Switch, on (green).

The reference is cut off below this row. The word "Sound" is just visible, so the card goes on with a sound option for this alert, and presumably an "Unplugged" row as well.
