# App Usage

Which apps are using the battery: who is using it right now, who used the most over a period, plain-language insights about apps behaving badly, and a per-app trend list.

**Header:** blue tile with three stacked layers, title "App Usage".

## Status line and range picker

In place of the usual subtitle, a grey status line on the left: "Less than a day of history collected • 10 apps tracked in the last 24h". The first part reports how much history exists; the second counts apps seen in the selected range.

On the right, segmented pills: "24h" (selected, indigo fill), "7d", "30d". The range drives the Top Drainers card, the insights, and the Top Energy Consumers list.

## Right Now and Top Drainers

Two cards of equal width side by side. Each is a ranked top-five list. A row is:
- the rank number in grey,
- the app's icon at about 24 pt,
- the app's name in white, with a thin horizontal bar underneath whose length is the app's share relative to the longest bar,
- the share as a percentage, right-aligned in bold.

Each app keeps one bar colour everywhere on this screen, so the eye can follow it between cards (the reference uses teal, red, purple, and pink).

**Right Now** (left card). Header: a grey bolt-in-circle icon and "RIGHT NOW" in grey small caps; on the right, grey "2m ago", the age of the last sample. The neutral card shows each app's share of current energy use.

| Rank | Share |
| --- | --- |
| 1 | 45% |
| 2 | 43% |
| 3 | 9.1% |
| 4 | 1.7% |
| 5 | 1.1% |

**Top Drainers · 24H** (right card). Header: an orange flame and "TOP DRAINERS · 24H" in orange small caps; the label follows the selected range. The card has a warm brown tint and an orange border to set it apart. It shows each app's share of total app energy over the range. The number-one share is coloured orange; the rest are white.

| Rank | Share |
| --- | --- |
| 1 | 50% |
| 2 | 29% |
| 3 | 18% |
| 4 | 0.95% |
| 5 | 0.90% |

Percentages use two significant figures below 10% and whole numbers above.

## Insights

Section label: a yellow sparkle and "INSIGHTS" in grey small caps.

A stack of insight cards. Each has a large icon on the left, a heading line with the app's small icon and a bold sentence, a grey explanation, and two buttons.

**Dominating insight.** Orange-tinted card with an orange border and an orange flame.
- Heading: "{app name} is dominating your battery"
- Text: "50% of your apps' total energy in the last 24h. If you're not actively using it, closing it could meaningfully extend battery life."
- Buttons: "See details" (orange tinted, bar-chart icon) and "Quit" (outlined, circled-× icon).

**Unusual-activity insight.** Neutral card with a yellow warning triangle.
- Heading: "{app name} is unusually active right now"
- Text: "It's drawing about 1.5× more energy than its typical share. It may be stuck in a loop or doing background work. Restart it if you're not actively using it."
- Buttons: "See details" and "Quit", both grey outlined.

So there are at least two insight rules:
- **Dominating:** one app's share of total app energy over the range is very large (50% here).
- **Unusually active:** an app's current share is well above its own typical share (1.5× here).

"See details" opens that app's detail view. "Quit" quits the app.

## Top Energy Consumers

Section label: a grey list icon and "TOP ENERGY CONSUMERS" in grey small caps.

One card with a row per app, separated by dividers. Each row has:
- the app icon at about 32 pt,
- the app name in white with its bundle identifier below in grey (such as `com.example.editor`),
- a wide sparkline filling the middle of the row: a thin red line with a faint red fill beneath it, showing energy over the selected range. In the reference every line is flat and then climbs steeply at the right end, because only a few minutes of history exist.
- on the right, the share in bold ("50%") with "of total" in grey below,
- a grey chevron. Clicking the row opens the app's detail view.

The reference shows three rows (50%, 29%, 18%) and is cut off. The list goes on through the apps tracked.
