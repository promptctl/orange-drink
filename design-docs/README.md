# Design docs

Screen-by-screen descriptions of the app's settings window, written from reference screenshots so the screens can be rebuilt without them. Read this file first: it covers the window frame, the sidebar, and the visual patterns every screen reuses. Each screen then has its own file.

`{App}` stands for the app's name wherever it appears in on-screen text. Numbers, device names, and app names in the descriptions are sample data, not requirements.

The menu bar panel (the popover that opens from the menu bar icon) is described in [PROJECT.md](../PROJECT.md#menu-bar-panel).

| Sidebar item | Doc | What it's for |
| --- | --- | --- |
| General | [general.md](general.md) | Language, appearance, launch at login, notification style |
| Alerts | [alerts.md](alerts.md) | Low-battery, charged, and power-source alerts |
| Menu Bar | [menu-bar.md](menu-bar.md) | Menu bar icon style and options |
| Charging | [charging.md](charging.md) | Charge limit |
| Devices | [devices.md](devices.md) | Bluetooth devices and Apple Watch |
| Widgets | [widgets.md](widgets.md) | Desktop and Notification Center widgets |
| Shortcuts | [shortcuts.md](shortcuts.md) | Global and in-menu keyboard shortcuts |
| App Usage | [app-usage.md](app-usage.md) | Which apps use the most energy |
| Battery | [battery.md](battery.md) | Mac battery history: level, daily usage, health |
| iPhone & iPad | [iphone-ipad.md](iphone-ipad.md) | Battery health of a cabled iPhone or iPad |

## Settings window

A standard macOS window in dark appearance, split into a sidebar on the left and a content area on the right. The content area scrolls vertically; the sidebar does not.

## Sidebar

A plain vertical list on a near-black background, with no visible border between it and the content area. Each item is a row holding an icon tile and a label:

- **Icon tile:** a rounded square about 28 pt across, filled with a solid colour, with a white glyph centred in it.
- **Label:** the screen name in medium-weight grey text, about 13 pt, left-aligned 12 pt after the tile.
- Rows are spaced generously, roughly 48 pt apart from one tile's top to the next.

The items fall into two groups. The second group has a small grey bold heading, "Insights", with extra space above it.

| Group | Item | Glyph | Tile colour |
| --- | --- | --- | --- |
| Settings | General | gear | yellow-green |
| | Alerts | bell | green |
| | Menu Bar | rounded window outline with a top bar | mint green |
| | Charging | heart with a lightning bolt cut through it | teal |
| | Devices | a phone overlapping a small tablet | cyan |
| | Widgets | 2×2 grid of rounded squares | sky blue |
| | Shortcuts | ⌘ (command key) | light blue |
| Insights | App Usage | three stacked layers | blue |
| | Battery | battery with a lightning bolt | periwinkle |
| | iPhone & iPad | a laptop screen with a phone beside it | indigo |

The tile colours step evenly through the hue wheel from yellow-green at the top to indigo at the bottom, so the sidebar reads as one gradient. The selected item's styling isn't visible in the reference; follow the standard macOS sidebar selection highlight.

## Shared patterns

Every screen is built from the same handful of parts.

**Screen header.** A bar across the top of the content area: the screen's sidebar tile (same colour and glyph, about 32 pt) followed by the screen name in bold white, about 20 pt. A thin hairline divider runs full width beneath it.

**Subtitle.** Directly under the header, one line of small grey text describing the screen, such as "Basic app settings and preferences".

**Section header.** A coloured line-art icon (no tile) followed by a bold white title about 17 pt. Each section's icon has its own colour. A section may have a grey info line under its title, prefixed with a small filled ⓘ.

**Setting card.** A rounded rectangle (about 12 pt corner radius) slightly lighter than the background, with a faint 1 pt border. A card holds one or more rows separated by hairline dividers inset from the left edge. A row is:

- On the left, an optional icon tile: a 28 pt rounded square with a dark tint of the icon's colour behind a coloured glyph. This is a muted version of the sidebar tile.
- A bold white title, with a grey description line underneath.
- A control right-aligned: a switch, a pop-up button, an info button, or a key recorder.

**Controls.**
- Switch: standard macOS toggle. The "on" colour varies by screen: green on Alerts, blue on Devices, indigo on Menu Bar.
- Pop-up button: a dark rounded button showing the current value with an up/down chevron (⌃⌄) on the right.
- Info button: a grey circled "i". Shows an explanation of the setting.
- Segmented pills: a row of rounded capsules for picking a time range or type. The selected pill is filled with an accent colour and has bold white text; the others are dark grey with grey text.

**Background.** Near-black, often with large, soft, low-opacity radial glows of colour behind the content, usually green and sometimes red or warm brown. The glows are decoration and don't track any data.

**Empty states.** Where a chart has no data yet, the card shows a centred icon, a bold heading, a grey explanation, and sometimes a small pill reporting progress, such as "1 day collected so far".
