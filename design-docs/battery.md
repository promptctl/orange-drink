# Battery

The Mac battery's history: current health, temperature, and cycles at a glance, then charts of battery level, daily usage, and health over time. The reference was taken on a fresh install, so the charts are in their empty states.

**Header:** periwinkle tile with a battery and lightning bolt, title "Battery".
**Subtitle:** "Daily usage, health, cycle, and temperature trends about your Mac over time"

## Stat tiles

Three cards of equal width in a row. Each has an icon and a small-caps grey label, a large white value, and a coloured status line:

| Label | Icon | Value | Status line |
| --- | --- | --- | --- |
| HEALTH | green heart | 95% | "Good", green |
| TEMPERATURE | green thermometer | 36.2°C | "Normal", green |
| CYCLES | blue circular arrows | 84 | "of 1000 rated", blue |

Status colours follow the reading. The reference shows only healthy readings.

## Battery Level

One card.

- **Header:** a green battery icon and "Battery Level" in bold white. On the right, range pills "24h" (selected, green fill), "7d", "14d".
- **Summary:** "Last charged to 79%" in bold white, with "Today, 2:42 AM" in grey below. This is the level and time of the most recent charge session's end.
- **Chart area:** a timeline of charge level over the selected range. In the reference it is empty and shows a centred grey hourglass with the text "Building your battery-level history — your charge timeline fills in as you use your Mac."

## Daily Usage

One card.

- **Header:** a green bar-chart icon and "DAILY USAGE" in grey small caps, then a yellow dot and "Collected 2m ago" in grey.
- **Chart area:** presumably one bar per day of battery discharge and screen-on time. In the reference it is empty and shows a centred empty state:
  - a green calendar-with-clock icon,
  - the bold heading "Building your daily usage",
  - grey text: "{App} tracks battery discharge and screen-on time across each day. Come back in a couple of days to see your charts fill in.",
  - a small dark pill with a hollow circle and the text "1 day collected so far".

  The reference prints "1 days". Pluralize correctly.

## Battery Health

One card.

- **Header:** a green heart and "Battery Health" in bold white, with an info button on the right.
- **Value:** "95%" in large white, with "Good" in green beside it. Right-aligned on the same line, grey "5,942 / 6,249 mAh" (full-charge capacity over design capacity).
- **Chart area:** the reference is cut off here. The top of an hourglass is visible, so this is a health-over-time chart, currently in the same empty state.
