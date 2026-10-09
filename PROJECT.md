# Project

An open-source macOS menu bar app for battery awareness. It replaces the system battery indicator with one that alerts at whatever charge levels you choose, tracks battery health over time, shows which apps drain the battery, and reports the battery of every nearby Apple device in one place.

The built-in macOS indicator alerts only at 10% and 5%, those levels cannot be changed, and on recent macOS releases it repeats the warning every minute. This app exists to fix that: alerts at levels you pick, delivered in a way you notice without being nagged.

This document describes functionality only. The project ships no third-party branding, artwork, or copy.

## Platform and quality bar

- Native macOS app written in Swift. No Electron or web-view shell.
- Targets Apple Silicon.
- Stays under 0.1% CPU in steady state. A battery monitor that drains the battery has failed at its job.
- Follows the macOS Human Interface Guidelines, so it looks and behaves like part of the system.
- Distributed outside the Mac App Store. Reading the Apple Watch battery (see below) needs system access the App Store sandbox blocks, so the unsandboxed build is the primary one.

## Features

### Menu bar icon

The app lives in the menu bar, and its icon is meant to replace the system battery icon. It shows the current charge and is themeable. Clicking it opens the panel described in [Menu bar panel](#menu-bar-panel).

### Custom battery alerts

You set alerts at any charge level, as many as you want, on the way down and on the way up. Typical setups:

- Low-battery warnings at 20%, 15%, and 3%.
- Last-chance alerts at 2% and 1%, so a video call doesn't drop without warning.
- A high-charge alert at 80% (see lifecycle alerts).

Each alert fires once when its threshold is crossed, not every minute.

### Notification styles

Alerts appear as small pill-shaped notifications that sit on screen without taking it over. Two optional stronger styles exist for when a pill isn't enough:

- **Screen glow:** a colored glow around the screen edges.
- **Full-screen alert:** covers the screen, meant for critical levels like 1–2%.

The style is chosen per alert, so 20% can be a quiet pill and 2% can be full screen.

### Battery health tracking

Records the battery's health over time so you can see how it is wearing. Health is the current full-charge capacity as a percentage of design capacity, shown alongside the cycle count against the battery's rated maximum. The panel's Battery Information section shows the live values.

### Temperature warnings

Alerts when the battery runs hot.

### Lifecycle alerts

Reminders that protect long-term battery life, chiefly an alert at 80% while charging telling you to unplug. Keeping a lithium battery out of the top of its range slows wear.

### Charge limits

Lets you cap charging at a set level. Detail to define: whether the app enforces the limit itself or only builds on what macOS already offers.

### App usage monitoring

Shows which apps are using the most energy, so you can see what is draining the battery.

### Desktop widgets

Battery information as macOS desktop widgets. Detail to define: which data each widget shows.

### Other devices' batteries

The menu bar shows the battery of every nearby Apple device, with low-battery alerts for each:

- AirPods and Beats headphones
- iPhone and iPad
- Magic Mouse and Magic Keyboard
- Apple Watch

The Apple Watch talks only to its paired iPhone, so the app reads the Watch battery through the iPhone. No companion app is installed on the iPhone or Watch. You connect the iPhone to the Mac by cable once; after that it works over Wi-Fi. This works only on Apple Silicon Macs and only in the unsandboxed build.

## Menu bar panel

Clicking the menu bar icon opens a dark, rounded panel about 330 points wide. Its contents are stacked rounded cards with thin borders. The three views below are taken from reference screenshots. Numbers in them are sample values, not requirements.

### Main panel, with Connected Devices expanded

From top to bottom:

1. **Charge card.** Top left, the charge level in large bold green digits ("78") followed by a smaller green "%". Below it, a yellow lightning bolt and the word "Charging". Top right, a small grey all-caps label "UNTIL FULL" above a bold time estimate ("1h 22m"). When the Mac is discharging, this would presumably show time remaining instead. Across the bottom runs a full-width rounded progress bar on a dark track, filled green to the charge level, with faint vertical tick marks at 25% and 50%.
2. **Battery Information.** A collapsible card with a blue circled "i" icon, the title, and a chevron on the right. It points down when collapsed and up when expanded. Expanded content is described in the next section.
3. **Apps Using Significant Energy.** A collapsible card with a lightning-bolt-in-a-circle icon. Collapsed in the screenshot. Expanded, it lists the apps currently drawing the most power (the app usage monitoring feature).
4. **Connected Devices.** A collapsible card with an icon of a phone beside a small device, shown expanded. Content is described below.
5. **Actions card.** A single card holding a list of rows separated by thin dividers. Each row has an icon on the left and a label:
   - Gear icon, "Settings…", with a right chevron. Opens the app's settings window.
   - Battery icon, "Battery Settings…", with a right chevron. Opens the macOS Battery pane in System Settings.
   - Leaf icon, "Low Power Mode", with an on/off switch on the right. Toggles macOS Low Power Mode directly from the panel.
   - Circular-arrows icon, "Check for Updates…". Checks for a new version of the app.
   - Red power icon, "Quit" followed by the app name. The app's version string (for example "v1.2.0") sits right-aligned in small grey monospace text on the same row.

   The reference also shows a trial-countdown row with an upgrade link between Low Power Mode and Check for Updates. It is left out here because licensing is out of scope.

### Battery Information, expanded

The card opens into four sections separated by thin horizontal dividers. Each section header has a status icon on the left (a green circled checkmark when the reading is healthy, or a section-specific icon) and a grey circled "i" button on the right that explains the section.

**Battery Health.** A large green "95%" with a green "Good" label beside it. On the right, a bold monospace "84/1000" over the caption "Cycle Count", meaning cycles used out of the rated maximum. Below, a full-width bar filled green to the health percentage.

**Temperature.** A green thermometer icon and a large green "30.9°C", with the Fahrenheit equivalent ("87.7°F") in grey underneath. On the right, a green checkmark and "Normal", with the grey caption "Optimal performance" below. The status and colour change when the battery runs hot; the temperature warnings feature is driven by the same reading.

**Power & Electrical.** Header icon is a green lightning bolt in a circle. Below it, a two-column grid of grey labels over bold monospace values:

- Left column: "Power Usage" 10.4 W, then "Current" 828 mA with a small green up-arrow badge meaning current is flowing into the battery.
- Right column: "Voltage" 12.62 V, then a green lightning bolt with "Charging" and the green caption "Normal voltage".

Under the grid is a **Power Flow** diagram, headed by a small icon and the grey title "Power Flow". It is a three-part flow chart:

- On the left, a tall rounded tile with a plug icon and the charger's rated wattage ("59W").
- On the right, two stacked square tiles: the top one holds a green charging-battery icon, the bottom one a laptop icon.
- Between them, two bands flow from the charger tile to the right-hand tiles, each as thick as its share of the power. The top band is green, labelled "10.4 W", and runs to the battery tile. The bottom band is grey, labelled "46.8 W", and runs to the laptop tile, representing what the system itself is consuming.
- Below the diagram, a centred caption: a lightning bolt with "Charging at 10 W", and under it in grey "Active workload: multitasking or media". The workload line classifies the current system draw into a plain-language description.

**Capacity Details.** Header icon is a blue battery. Three rows of grey labels with right-aligned monospace values:

- "Remaining" 4635 mAh, in green. Divided by full capacity, this is the charge percentage (78%).
- "Current Full" 5942 mAh, in blue. Divided by design capacity, this is the health percentage (95%).
- "Design Capacity" 6249 mAh, in grey.

At the bottom of the card, three centred lines: a small grey "ⓘ We refresh your battery health stats every 2 min", then "Updated 3 min ago", then a blue "↻ Tap to refresh now" link that forces an immediate refresh.

### Connected Devices, expanded

A list of every Bluetooth or nearby Apple device that reports a battery level, one row per device, separated by thin dividers that are inset to line up with the text. Each row has:

- On the left, an outline icon for the device type. A phone icon for phones, a tablet icon for tablets, and a wireless-signal icon (concentric arcs around a dot) for audio and other wireless accessories.
- The device's own name in white, such as the name the owner gave their iPhone.
- The battery percentage, right-aligned in bold.
- Under the name and percentage, a thin rounded bar filled to the battery level.

Bars and percentages are light grey for normal levels and turn green when a device is nearly full; the reference shows green at 95% and grey at 54% and below. Presumably they turn a warning colour when a device is low, matching its low-battery alert.

## Out of scope

- Trials, licensing, and payment. This is open source.
- General system monitoring (CPU, network, disk). The app is purpose-built for batteries.
