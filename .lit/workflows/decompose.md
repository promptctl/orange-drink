---
# Fires when an agent opens or starts an epic labelled `decompose`. Epics are not
# leaves, so `lit next` never serves them; the planning campaign
# (plan-campaign.md) is what routes agents here.
id: decompose
name: Break an epic into rough tickets
labels: ["decompose"]
events: [show_ticket, work_started]
---
<id> carries `decompose`: turn its scope into child tickets. This pass is coarse on purpose. Each child gets a title, a topic, and one or two sentences of outcome. The detail comes later, from the `refine` workflow, when the child reaches the top of the backlog. Detail written now goes stale before anyone builds it.

For each item in <id>'s Scope:
- File one child per outcome that fits in a PR: `lit new --parent <id> --labels refine --topic <topic> --title "..." --description "..."`. An item too big for one PR becomes several children.
- If nobody yet knows how to do it, the first child is a research ticket: label it `spike,refine`, title it as the question it answers, and say in its description what prototype will settle it.
- File children in build order: lit appends each new ticket to the bottom of its epic, so creation order becomes rank order. Within the epic, rank is the dependency. Dependencies on other epics are `blocks` edges.

Not in this pass: acceptance checks, design-doc citations, splitting hairs over size, or any code. Those belong to `refine` or to the build.

Stop when every Scope item maps to at least one child. Then:
1. Comment on <id> with that mapping, one line per Scope item followed by the child ids that cover it. This mapping is the check: an item with no child is a gap.
2. Show the user the children's titles in rank order and wait for their approval. This is one of the two points where a human signs off.
3. Once approved, `lit label rm <id> decompose`.

You will want to skip the mapping comment because the children "obviously" cover the scope. The comment is what lets the next agent see a gap without re-deriving the breakdown.
