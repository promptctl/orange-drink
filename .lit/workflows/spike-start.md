---
# A spike answers a question with a prototype. This fires as one is started, to
# keep it from growing into the feature it was meant to de-risk.
id: spike-start
name: Work a research ticket
labels: ["spike"]
events: [work_started]
---
<id> is a spike: its deliverable is an answer, not a feature. Answer the question in its title with the smallest prototype that proves the answer on a real Mac. Then record the finding as a comment on <id>: the method that works, the methods that didn't and why, the API or command that does it, any permission or entitlement it needs, and its CPU or latency cost if that matters.

Out of scope: UI, settings, error handling beyond what the proof needs, and wiring into the app. Keep the prototype under `spikes/<id>/` so nobody mistakes it for product code.

Stop when the comment answers the title's question with evidence: output pasted from the prototype run, not a claim that it works. If the answer is "it can't be done this way", that is a finished spike too. Say so and say what you tried. Partway through, the prototype will start to look nearly shippable and you will want to finish it as the feature. Don't: the feature ticket ranked below this one has its own refine pass, and it needs your finding, not your prototype.
