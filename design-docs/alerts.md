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
- **Position:** "Center of Screen", "Top of Screen", or "Full Screen". The first two place a pill; "Full Screen" is the full-screen alert below.
- **Border Glow:** on or off. This is the screen edge glow. With "Full Screen" the editor hides the switch and the summary leaves it out, since nothing of the screen is left uncovered to glow; the saved value is kept for a switch back to a pill.
- **Sound:** on or off. The summary lists only the options that are on.

An alert saved before "Full Screen" existed keeps the position it was saved with.

The reference colours red at 5% and below and yellow at 15%. Severity is presumably assigned by threshold band.

Under the stack is a centred, dark, rounded button: "＋ Add Low Battery Alert".

## Full-Screen Alert

Not in the reference. PROJECT.md promises it for critical levels like 1–2%, where a pill that leaves after eight seconds is easy to miss. Low and charged alerts can choose it. The power-source and temperature pills cannot. It is for the Mac's own battery: a watched device that fires an alert set to "Full Screen" shows a Center of Screen pill, without the glow, since the hidden Border Glow switch can't be seen or changed.

**What it shows.** A dark, translucent cover over the whole screen, menu bar and Dock included, with one block centred on it:

- The charge ring at a large size, drawn in the alert's severity colour and filled to the remaining charge, as the pill's ring is.
- The pill's headline in large bold type, such as "2% Remaining" or "80% Charged".
- The pill's second line under it, such as the time remaining, and left out when the pill would leave it out.
- One button, "Dismiss".

**What dismisses it.**

- The "Dismiss" button.
- Esc.
- The power adapter being connected, for a low alert: the alert has been answered. The Plugged In pill then shows as usual if its switch is on.
- The power adapter being disconnected, for a charged alert: the alert has been answered. The On Battery pill then shows as usual if its switch is on.
- A newer full-screen alert, which replaces it.

A low or charged pill for the Mac that fires while it is up doesn't show, including another low alert crossed on the same reading: the cover already says more than the pill would. Temperature and watched-device pills show over the cover as usual, since the cover says nothing about them. A pill already up when the cover appears is taken down.

It has no countdown. Its ring, headline and second line follow the battery while it is up, so what it says stays true. It stays until one of these happens, including through a sleep or a lock, so it is still there when the person comes back. Each time it comes back to the front, after an unlock or a wake, it takes keyboard focus again, and again ignores keys and clicks for its first second. An alert that fires while no display is connected appears on the first display connected.

**Focus and input.** It takes keyboard focus while it is up, so Esc reaches it and typing doesn't go into the app underneath. For its first second it ignores keys and clicks, so a keystroke already on its way, such as an Esc in an editor, doesn't dismiss it unread. Clicks on the cover land on the cover, not on what is beneath. It is a deliberate interruption, and the two ways out (the button and Esc) are always one action away. Orange Drink's panel and Settings don't open while it is up. When it is dismissed, the app that was frontmost before it appeared is frontmost again. VoiceOver reads the headline and second line when it appears and lands on "Dismiss".

**Several displays.** It covers every connected display, each with the same centred block. Dismissing it on any display clears every one. A display connected while it is up gets covered too, and a display removed takes its cover with it. Keyboard focus sits on the cover of the primary display, the one System Settings › Displays marks as main.

**Full-screen apps.** It covers them as it covers the desktop, joining every Space as the pill and glow do, at the pill's level, so nothing of Orange Drink's sits above it except the temperature and device pills.

**Screen sharing.** It does nothing special: someone watching a shared screen sees it as the person sharing does. A battery level is not private, and a cover the sharer sees but viewers don't would make the sharer's screen and the shared one disagree.

**Sound.** The alert's Sound switch decides whether it plays a sound, once, when it appears, as a pill does.

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

**When it fires.** On the reading where the battery leaves Normal: from under 35 °C to 35 °C or more, whether that is Warm (35 up to 40 °C) or Hot (40 °C and over). After that it stays quiet, including when a Warm battery goes Hot, until the battery has cooled to under 33 °C (two degrees back from the Warm boundary, as the low and charged alerts re-arm five points back) and then reached 35 °C again. A battery hovering around 35 °C, such as 34.9, 35.1, 34.9, 35.2, is one warning, not one per upward crossing; one that cooled only to 34 °C says Normal in the panel and is still not re-armed. A Mac that launches already warm or hot does not announce it, and warns only after cooling under 33 °C and warming again. The warning names the state the panel shows.

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
