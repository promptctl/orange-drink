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

The app lives in the menu bar, and its icon is meant to replace the system battery icon. It shows the current charge and is themeable. Clicking it opens a menu with battery status and the connected devices listed below.

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

Records the battery's health over time so you can see how it is wearing. Detail to define: which metrics to show. Likely candidates are maximum capacity against design capacity and cycle count.

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

## Out of scope

- Trials, licensing, and payment. This is open source.
- General system monitoring (CPU, network, disk). The app is purpose-built for batteries.
