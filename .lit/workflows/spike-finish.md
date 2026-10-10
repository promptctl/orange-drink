---
# Fires as a spike closes. Its job is to carry the finding forward into the
# tickets that were waiting on it. This is the back-edge that sends work
# around the refine loop again.
id: spike-finish
name: Carry a spike's finding forward
labels: ["spike"]
events: [work_finished]
---
Spike <id> is closed. Its finding only helps if it reaches the tickets that were waiting on it. Find them: `lit ls --search <id>` (they say "Waits on <id>"), `lit dep ls <id>`, and the tickets ranked right after <id> in its epic.

For each one:
- Add a comment summarising the finding in two or three lines, citing <id>.
- If the finding changes what the ticket must do, or makes it impossible, put `refine` back on it (`lit label add <ticket> refine`) so its description is brought up to date before anyone builds it.
- Delete its "Waits on <id>" line.

If the finding breaks the plan itself (the feature can't be built, or needs a permission or entitlement that changes distribution), stop and tell the user before you touch anything else. That is the second point where a human signs off.

You are done when no open ticket still says "Waits on <id>".
