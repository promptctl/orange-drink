# Alerts

Turns notifications on or off, and holds the list of alerts: low-battery thresholds, charged thresholds, power-source events, and a battery temperature warning. Each threshold alert has its own position on screen, glow, and sound.

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

## Temperature Warning

Not in the reference. The Battery Information card's Temperature section already calls a battery Normal, Warm, or Hot; this alert tells the person when it stops being Normal, so a battery running hot is not noticed only by opening the panel.

**When it fires.** On the reading where the battery leaves Normal: from under 35 °C to 35 °C or more, whether that is Warm (35 up to 40 °C) or Hot (40 °C and over). It does not fire again while the battery stays out of Normal, including a Warm battery going Hot, and fires once more only after a reading back in Normal. A Mac that launches already warm or hot does not announce it. The states are the panel's, so the pill appears exactly when the panel stops saying "Normal".

**The pill.** Same shape as the Plugged In and On Battery pills: at the top of the screen, the charge ring around it, no Border Glow.

| Battery | Headline | Colour |
| --- | --- | --- |
| Warm | "Battery Warm" | orange |
| Hot | "Battery Hot" | red |

- **Second line:** the reading in the panel's wording, °C then °F, one decimal each, such as "41.2°C / 106.2°F". It replaces the time estimate the other power pills carry there, as the reading is what this alert is about.
- The colours are the panel's own: orange for Warm, red for Hot.

**The row.** One more row in the Power Source Alerts card, between "Unplugged" and "Sound":

- Orange tile with a white thermometer.
- Title "Temperature", description "Notify when the battery runs warm or hot".
- Switch, on (green), labelled "Temperature" for VoiceOver. A setting saved before this row existed reads as on.

**Sound and glow.** The card has one "Sound" row, "Play a sound for these alerts", shared by every row above it; the Plugged In and Unplugged rows have no sound or glow choice of their own, and the Temperature row has none either. The Sound switch decides whether the temperature pill chimes, and the pill never glows.

**Switches.** The Temperature switch off silences the pill and its sound. "Enable Notifications" off silences it with every other alert.
