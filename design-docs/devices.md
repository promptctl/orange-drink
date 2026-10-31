# Devices

Controls which other devices' batteries appear in the menu bar panel, sets up the Apple Watch, and lists every detected device with per-device alert, pin, and hide buttons.

**Header:** cyan tile with a phone overlapping a small tablet, title "Devices".
**Subtitle:** "Monitor battery levels of your AirPods, Beats, Magic Mouse, Keyboard, Trackpad, and other paired Bluetooth devices."
**Background:** green glow at the top centre.

## Bluetooth Devices

Section icon: blue Bluetooth rune.

One card with one row:

- Grey tile with the devices glyph.
- Title "Show Connected Devices", description "Display battery levels for paired Bluetooth devices in the menu bar dropdown".
- Switch, on (blue). Shows or hides the Connected Devices section of the menu bar panel.

## Apple Watch

Section icon: blue watch.

One card. Top row:

- Grey tile with a watch glyph.
- Title "Show Apple Watch", description "Reads your Watch's battery through your iPhone. Plug the iPhone in once and tap Trust: after that it works over Wi-Fi."
- Switch, off.

Below a divider, two grey paragraphs explain the setup:

> When you plug your iPhone in, {App} switches on Wi-Fi sync for it, so you won't need the cable again. You can turn that off anytime in Finder.

So the Watch flow is: the user connects the iPhone by cable once and trusts the Mac. The app then turns on the iPhone's "Show this iPhone when on Wi-Fi" setting and reads the Watch battery from the iPhone over Wi-Fi from then on. usbmuxd makes that Wi-Fi connection, not {App}, so macOS asks for no Local Network permission (lm3.1tt: Wi-Fi readings arrived with {App} absent from the Local Network list).

## Detected Devices

Section icon: white antenna sending out waves.

One card listing every device that reports a battery. Rows have no dividers. Each row has:

- **Left:** an outline glyph for the device type, with no tile. A phone for phones, a tablet for tablets, and concentric arcs around a dot for audio and other wireless accessories.
- **Name and level:** the device's name in white, with its battery percentage in small grey text below, such as "37%".
- **Right, three circular dark-grey buttons, about 32 pt each:**
  1. **Bell, crossed out:** alerts for this device are off. Tapping it sets battery alerts for the device.
  2. **Pushpin, outline:** not pinned. Tapping it pins the device's battery into the menu bar itself, next to the main icon.
  3. **Eye, white:** visible in the menu bar panel. Tapping it hides the device; the icon becomes an eye with a slash.

Rows are sorted by battery level, lowest first. The reference shows 37%, 49%, 54%, then 95%. A device whose level can't be read right now keeps its row below the rest, with an en dash for its level.

## Help list

Below the card, without a card around it, six help lines. Each has a small coloured icon tile and grey text:

| Tile | Text |
| --- | --- |
| orange bell | Tap the notification icon on any device to set battery alerts. |
| cyan pushpin | Tap the pin icon to show a device's battery right in the menu bar. Arrange the order in the [Menu Bar settings](menu-bar.md). (The last phrase is a blue underlined link to that screen.) |
| blue eye with slash | Tap the eye icon to hide a device from the dropdown. |
| grey up/down arrows | Devices are ranked by battery level, lowest first, so the one that needs charging is always at the top. |
| blue phone | To see your iPhone or iPad battery, make sure it's Bluetooth-paired with this Mac via System Settings → Bluetooth. |
| green seal with checkmark | Most devices provide exact battery levels. For some devices, we use approximate values prefixed with a tilde (~). |

The last line sets a display rule: a device that only reports an approximate level shows it as "~50%" wherever its level appears.
