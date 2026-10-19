---
# Overrides lit's embedded "done" definition (same id, so this project file
# replaces it whole). The first paragraph is the embedded text unchanged; the
# second adds this project's back-edge into the refine loop.
id: done
name: Post-close capture reminder
events: [work_finished]
---
Ticket <id> has been closed. Before moving on, take a moment to review related tickets. Did anything in this work change what future work should look like? Is there anything you now know that would help the next agent? If so, update those tickets to capture it. Keeping them current is what keeps future work from drifting or unintentionally reversing decisions made here, so it's worth doing now rather than later. In most cases you can make these updates directly and note them in a short summary for the user; if a change carries real risk, it's fine to check with them first.

If what you learned makes an already-refined ticket's description wrong (its outcome, its "Done when:" check, or its dependencies), put `needs-refinement` back on it with `lit label add <ticket> needs-refinement` rather than patching one line. It will be brought fully up to date when it reaches the top. Work you discovered that has no ticket yet goes in with `lit followup --on <id> --title "..." --labels needs-refinement`.
