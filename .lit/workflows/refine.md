---
# Fires when an agent is looking at, pulling, or starting a ticket labelled
# `refine`. Not on ticket_updated: adding the label is itself an update, and the
# agent doing the labelling is not the one doing the refining.
id: refine
name: Refine a ticket until it is ready to build
labels: ["refine"]
events: [show_ticket, next_pulled, work_started]
---
<id> carries `refine`: it is not ready to build yet. Refine it first, even if you pulled it meaning to build it. The one exception is a running planning campaign: if its guidance is printed beside this, follow that instead. Writing code for a ticket that still has `refine` on it is out of bounds.

The ticket is ready when every line below is true of its description. Check each one against the text itself, not against what you know:

1. It says what to build and why, in terms a user or the design docs would recognise.
2. It has a "Done when:" line naming a check someone else can run: a test, a command, or a step on a real Mac with the expected result.
3. It points at the design doc or PROJECT.md section it implements, or says there is none.
4. Anything it needs from outside its epic is wired as a `blocks` edge (`lit dep add --from <blocker> --to <id>`). Inside its epic, rank order is the dependency, because lit refuses blocks edges between siblings.
5. It fits in one PR.
6. It has no open question about how. If one remains, file a research ticket beside it: `lit new --parent <id's parent> --labels spike,refine --topic <id's topic> --title "<the question>"` (`lit show <id>` names the parent; leave `--parent` out if there is none), then `lit rank <spike-id> --above <id>`, and write "Waits on <spike-id>" into <id>'s description. Leave `refine` on <id>, then go and work the spike.

If <id> fails line 5, it is several tickets. Split it into siblings that replace it: file each piece with `lit new --parent <id's parent> --labels <id's labels> --topic <id's topic> --title "<piece>"`, adding `--priority` and `--lane` if <id> has them, and rank each with `lit rank <piece> --above <id>` in build order. Move every `blocks` edge on <id>, and every "Waits on <id>" line in another ticket, to the piece it belongs to. Then `lit close <id> --resolution superseded --of <first piece>` and stop. Do not turn <id> into an epic: lit refuses the type change. Each piece goes through this same workflow when it reaches the top. That is the recursion, and it ends at tickets that fit in one PR.

Refining is not designing the implementation. Describe the outcome and the check, not the classes or files: the description has to stay true after a refactor.

Stop when all six lines hold: `lit label rm <id> refine`, then add a one-line comment saying what changed. You will be tempted to call a vague "Done when:" good enough because the work feels obvious. It is obvious only to you, now; the agent who builds this sees just the text.
