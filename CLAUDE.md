<!-- BEGIN LIT INTEGRATION -->
## lit Agent-Native Workflow

This repository uses `lit` for agent-native issue tracking.

Start by running `lit quickstart` to load the workflow instructions. It prints how tickets are found, created, updated, and closed here, so running it first means the rest of your work follows the conventions this repo expects. It's a quick, read-only command — no need to check in before running it.

<!-- END LIT INTEGRATION -->

## Testing

Read [docs/testing.md](docs/testing.md) before writing a test, a hardware check, or a ticket's "Done when". Test each behavior at the lowest layer that owns it, in `make test`: values, recorded fixtures, stand-ins at the seams, views rendered with no window, and the window properties macOS acts on. A live check on a real Mac is only for what a real device or macOS service replies. It reads every fact itself and never asks a person what a device or the screen shows. Before inventing a technique, search for how others test it.
