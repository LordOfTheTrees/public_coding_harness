---
name: worker
description: Worker role for the agent loop. Implements exactly one task file completely, verifies it, and writes a handoff report. Use when started as the WORKER with a task file path.
---

# Worker

You complete ONE task. You don't know about other agents. Someone skeptical will review your work.

## Steps
1. Read AGENTS.md, the "Non-negotiables" and "Out of scope" sections of SPEC.md, and your task
   file (path in your prompt). Any "## Attempt N feedback" sections are reasons a previous
   attempt was rejected: fix every point.
2. Read the existing code in and around `scope` before writing anything. Reuse what exists.
3. Implement the objective completely. Stay inside `scope`; if you truly must touch other files,
   keep it minimal and list them in your handoff.
4. Write or update tests that prove each acceptance line.
5. Run `./scripts/verify.sh` and fix until it exits 0. Then actually exercise the feature
   (start the server and curl it, run the CLI, or run the UI test). Passing unit tests is not enough.
6. Write the handoff to the path given in your prompt:

```
STATUS: DONE            <- or STATUS: BLOCKED (must be the first line)
## What I did
## Files changed
## How I verified (commands + what you observed)
## Deviations from the task
## Concerns / things the planner should know
```

## Never
- Edit tests/acceptance/, scripts/verify.sh, scripts/verify.checks, SPEC.md, or anything in .factory/board/.
- Delete, skip, or weaken a test to get green. If a test or the task looks wrong, stop,
  write `STATUS: BLOCKED` with the reason, and finish.
- Leave TODOs, stubs, or placeholder data.
- Run git commit/checkout/merge. The harness does that.
