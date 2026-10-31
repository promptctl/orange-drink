# General

Basic app settings: language, light or dark appearance, launch at login, suppressing the system's own battery notifications, and how this app's alerts look.

**Header:** yellow-green tile with a white gear, title "General".
**Subtitle:** "Basic app settings and preferences"

## Language

Section icon: blue globe.

One card with one row:

- Blue globe tile.
- Title "App Language", description "Choose the language {App} uses. Changes apply immediately."
- Pop-up button, value "Match System". Other values are the supported languages.

## Appearance

Section icon: purple circle half filled.

One card with one row:

- Purple half-circle tile.
- Title "App Appearance", description "Auto follows your Mac's system appearance".
- Pop-up button, value "Auto". Auto, Light, or Dark; applies at once to the settings window and the panel and is kept across launches.

## System Integration

Section icon: green power symbol.

One card with one row:

- Green power-symbol tile.
- Title "Launch at Login", description "Start {App} automatically when you log in".
- Switch, off.

macOS holds a login item until the app is allowed in the background, so a press on a new install leaves the switch off, and the row says so with a link to Login Items & Extensions. Coming back once it is allowed shows the switch on.

## System Notifications

Section icon: red-orange square with a dot on its top-right corner (a notification badge).

One card with one row:

- Red tile with a crossed-out bell.
- Title "Dismiss macOS Battery Notifications", description "Automatically closes system battery notification on the top right so you don't have to click it away."
- Switch, off.

When on, the app closes the battery notifications macOS posts in the top-right corner, so users who rely on this app's alerts don't get both.

## Notification Appearance

Section icon: pink-magenta four-pointed sparkle.

One card holding three rows with no icon tiles, separated by dividers:

1. "Alert Bubble Size", pop-up button, value "Default". Scales the alert pill.
2. "Screen Edge Glow", pop-up button, value "Default". Sets the strength or style of the glow around the screen edge.
3. A small row with the grey label "Preview" on the left and, on the right, a small switch (off) labelled "Show Glow".

Below the third row is a large preview area: a rounded rectangle darker than the card that shows a live sample alert. With "Show Glow" on, the preview presumably also shows the edge glow.

### The sample alert pill

This is the app's standard alert, shown here as a preview:

- A wide capsule, roughly 280 × 64 pt, filled near-black, with a thick (about 6 pt) dark-grey border.
- The border doubles as a progress track. An orange stroke traces it, starting at the left end, curving around it, and running along the top edge for about a third of the width. The orange part shows the remaining charge.
- On the left inside the capsule, an orange battery outline with a small orange fill: a low battery.
- In the middle, two lines: "15% Remaining" in large bold white, and "9min until empty" in lighter white below.
- On the right, a circular dark-grey close button with a thin "×".

The colours follow the alert's severity. Orange is used here for 15%. See [alerts.md](alerts.md) for how thresholds are coloured.
