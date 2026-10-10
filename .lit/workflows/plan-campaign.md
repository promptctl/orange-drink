---
# A campaign is a temporary workflow. It fires on every backlog view and every
# `lit next` until its stop condition holds; then the agent deletes this file and
# the campaign is over. Start a new campaign by writing a new file like this one.
id: plan-campaign
name: "Campaign: break every epic into tickets"
events: [show_backlog, next_pulled]
---
A planning campaign is running. Until it ends, breaking down epics comes before building.

Check the stop condition first: `lit ls --labels decompose --status open`.

- **Any epics listed:** take the highest-ranked one, run `lit show <epic-id>`, and follow the `decompose` guidance that appears. Leave what `lit next` offered for later.
- **None listed:** the campaign is finished. End it:
  1. `git rm .lit/workflows/plan-campaign.md`
  2. Commit with the message "End planning campaign: every epic decomposed".
  3. Tell the user, and suggest a backlog groom (the groom-backlog skill) before building starts.

  Then carry on with `lit next` as normal.

This campaign only files and orders tickets. It writes no product code, and it doesn't refine tickets ahead of their turn: `refine` fires on its own as each ticket reaches the top. If you notice you're writing acceptance checks for a ticket three epics away, you've drifted. Stop and go back to the stop check.
