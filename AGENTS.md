# AGENTS.md — rules every agent follows (Claude Code, Codex, Cursor all read this)

## Project
- Product spec: SPEC.md (source of truth for WHAT to build)
- Run checks: `./scripts/verify.sh`  (must exit 0 before any task is "done")
- Coordination state (tasks, handoffs, reviews, progress) lives in `.factory/` — not in git.

## Roles
This repo is worked on by an automated loop with four roles. When the loop starts you,
it tells you your role and points you at `.agents/skills/<role>/SKILL.md`. Read it and follow it exactly.
- planner   — turns SPEC.md into small task files. Never writes product code.
- worker    — completes exactly ONE task file. Never edits tasks, tests in tests/acceptance/, or scripts/verify.sh.
- evaluator — skeptically reviews ONE finished task. Never fixes code.
- cleaner   — small behavior-preserving refactors on recently merged code.

## Hard rules (all roles)
- Never run `git commit`, `git checkout`, `git merge`, or `git push`. The harness owns git.
- Never edit, skip, or weaken files in `tests/acceptance/`, `scripts/verify.sh`, or `scripts/verify.checks`.
- No TODOs, stubs, fake data in real code paths, or partial implementations.
- Keep command output short; write long logs to `.factory/logs/`.

## Stack notes (fill in for your project)
- Language/framework: <fill in>
- Install: <command>
- Dev server: <command>
- Conventions: <where code lives, and which modules tests may import>

## Learnings (cleaner/planner append short bullets here when they find a repeated mistake)
- <none yet>
