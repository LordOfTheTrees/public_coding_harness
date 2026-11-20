# Agent Factory

Author: LordOfTheTrees · [TreePage](https://lordofthetrees.github.io/TreePage/)

Pull requests are welcome. Reviews may be slow.

A stack-agnostic coding harness. Fork it, write a spec, and one bash loop runs a planner, a worker, an evaluator, and a cleaner until the spec is done. The agents can be Claude Code, Codex, or Cursor. A mock agent exercises the plumbing with no model and no API key.

The kit is the loop, the skills, and a blank spec. It does not ship application code or a filled-in product spec. Those stay on your machine.

```
                ┌──────────────── harness/loop.sh (bash, deterministic) ────────────────┐
 SPEC.md ──▶ PLANNER ──▶ task files ──▶ WORKER (branch task/T-00X) ──▶ verify.sh ──▶ EVALUATOR
                 ▲                                                        │fail          │
                 │                       feedback appended to task ◀──────┴──────────────┤
                 │                                                                       │pass
                 └──────────── PROGRESS.md ◀── merge to main ◀────────────────────────────┘
                                                 every 3 merges ──▶ CLEANER ──▶ verify.sh (else revert)
```

## Start here

1. Fork this repository and clone your fork.
2. Copy the blank spec and run setup from the repo root:

   ```bash
   cp templates/SPEC.md SPEC.md
   bash harness/setup.sh
   ```

   `setup.sh` copies the template only when `SPEC.md` is missing, creates the gitignored `.factory/` board, and symlinks skills into `.claude/skills` and `.cursor/skills`.
3. Fill in the spec. In Claude Code or Cursor, say: "Use the spec-interview skill. My idea is: …" Answer its questions. You want 3–7 user stories, each with an acceptance check a tester could observe, plus an explicit out-of-scope list. `SPEC.md` is gitignored.
4. Fill "Stack notes" in `AGENTS.md`. Put the project's real check commands in `scripts/verify.checks` (one per line). A commented TypeScript + Vite example is in `scripts/verify.checks.example`. Commit those on the base branch.
5. Dry-run the plumbing with no model:

   ```bash
   AGENT_CLI=mock MAX_ITERS=10 CLEAN_EVERY=1 bash harness/loop.sh
   ```

   You should see plan, work, one rejection, a retry, merges, cleanup, and then DONE.
6. Run it for real inside a sandbox (a VM, a dev container, or a spare machine), with a spend cap on the agent account:

   ```bash
   AGENT_CLI=claude MAX_ITERS=60 bash harness/loop.sh
   ```

## Requirements

- Git
- Bash
- Python 3 (the loop uses it to read usage-limit messages)
- For a real run, one of: Claude Code (`claude`), Codex CLI (`codex`), or the Cursor CLI (`agent`)
- For a mock run, none of those CLIs
- Whatever tools your own `scripts/verify.checks` commands call, once you add them

Names the harness reads from the environment are listed, without values, in `.env.example`. The loop does not source `.env`. Export the knobs in the shell.

## Optional: Jev (TypeSafe System One) judgments

`harness/jev.sh` is a standalone client. The loop does not call it yet. You send a state and typed questions; it returns a yes/no probability, a choice, or a score. It does not edit files or replace the coding agent.

`TYPESAFE_API_KEY` comes from the environment, or from that one assignment in a gitignored `.env` when the variable is unset. The key must never be committed. `JEV_MODEL` defaults to `jev-latest`. `TYPESAFE_API_URL` defaults to `https://api.typesafe.ai/v1/systemone`.

```bash
harness/jev.sh test              # one canned request; prints the judgment only
harness/jev.sh < request.json    # raw System One body on stdin; prints JSON
```

## The loop

Judgment stays in the agent. Mechanics stay in bash.

| Role | When it runs | Reads | Writes |
|---|---|---|---|
| spec-interview | You, once, before the loop | your idea | `SPEC.md`, stack notes in `AGENTS.md`, `scripts/verify.checks` |
| planner | Whenever the todo column is empty | spec, progress, handoffs, reviews | 3–8 task files, a rewritten `PROGRESS.md`, or `DONE` |
| worker | One task at a time, on branch `task/<id>` | that task file | code, tests, a handoff |
| evaluator | After `verify.sh` passes | task, handoff, diff | a review whose first line is `VERDICT: PASS` or `VERDICT: FAIL` |
| cleaner | Every `CLEAN_EVERY` merges (default 3) | the recent diff | small refactors, reverted automatically if checks fail |

`harness/loop.sh` is the only thing that commits, checks out, merges, or pushes. Agents are told not to run git. Pass or fail is the first line of the review file. The loop does not interpret the prose under it.

Three kinds of instructions stay apart so the same board can move between tools:

| Kind | What it is | Where |
|---|---|---|
| Rules | Facts and "never do X" for every agent | `AGENTS.md` (`CLAUDE.md` imports it) |
| Skills | The procedure for one role | `.agents/skills/<role>/SKILL.md` |
| Harness | Steps that must happen the same way every time | `harness/*.sh`, `scripts/verify.sh` |

If a mistake would be catastrophic, or the step is mechanical, it belongs in bash.

## How a run stays portable

1. One rules file. Codex and Cursor read `AGENTS.md`. `CLAUDE.md` contains only `@AGENTS.md`, which Claude Code imports.
2. One skills folder. `.agents/skills/` is the source of truth. Setup symlinks it for interactive sessions. The loop does not depend on that: every prompt says to read `.agents/skills/<role>/SKILL.md`.
3. One adapter. `harness/agent.sh` is the only file that names a vendor CLI. Switch with `AGENT_CLI=claude|codex|cursor|mock`. Per-role models are `MODEL_PLANNER`, `MODEL_WORKER`, `MODEL_EVALUATOR`, and `MODEL_CLEANER`.
4. State is files plus git. The board is `.factory/` (gitignored). Stop a run, change `AGENT_CLI`, and continue. Nothing the loop needs lives in a vendor session.

On Cursor, the planner and evaluator default to `grok-4.7` and the worker and cleaner default to `composer-2.5`. A Claude run maps those to `sonnet` and `claude-4.5-haiku`. Codex ignores those ids and uses its own default. Set `MODEL_<ROLE>` to override.

CLI flags change often. If a run dies instantly, open `.factory/logs/`, check `<cli> --help`, and fix the matching line in `harness/agent.sh`.

## Checks and the tamper gate

`scripts/verify.sh` is the pass/fail gate. A fresh fork passes and prints a notice, because no stack is configured yet:

```bash
./scripts/verify.sh
```

Pass a base ref to also run the tamper check:

```bash
./scripts/verify.sh origin/main
```

Protected paths are `scripts/verify.sh`, `tests/acceptance/`, and `scripts/verify.checks`. A branch that edits them relative to the base ref fails before review. A diff that adds `.skip(`, `.only(`, `xit(`, `xdescribe(`, or `@pytest.mark.skip` fails the same way. Agents may run the script. They may not weaken it.

Project commands live in `scripts/verify.checks`, one per line. Blank lines and `#` comments are ignored. Copy `scripts/verify.checks.example` and uncomment a stack, or write your own. Commit that file on the base branch before the loop starts, so task branches cannot replace it. An unknown base ref is an error. The tamper check does not silently skip.

Human-written acceptance tests belong in `tests/acceptance/`. See `tests/acceptance/README.md`. The kit ships no product tests.

## What stays out of git

| Path | Why |
|---|---|
| `SPEC.md` | The spec you are writing. `templates/SPEC.md` is the blank form and is tracked. |
| `.factory/` | Tasks, handoffs, reviews, logs, and progress. The loop recreates the board. |
| `.env` | Local secrets and machine-specific variables. `.env.example` lists names only. |

The ignore file is an allowlist: markdown, `LICENSE`, `harness/`, `scripts/`, `tests/acceptance/`, and the skill symlinks are tracked. Everything else is not, until you un-ignore the files a product needs. A commented TypeScript + Vite example is in `.gitignore`. Keep `.env`, `.factory/`, and `/SPEC.md` ignored.

## Steering while it runs

| Symptom | What to do |
|---|---|
| Tasks bounce between worker and evaluator | The task is too big or too vague. Split it in `.factory/board/todo/`, or add a clearer Notes section. |
| Tasks land in `.factory/board/blocked/` | Read the handoff in `.factory/handoffs/`. Fix `SPEC.md` if the spec contradicts itself, delete the blocked task, and let the planner run again. |
| The evaluator passes broken work | Add the failure as a rule in `.agents/skills/evaluator/SKILL.md`. |
| The same mistake shows up on many tasks | Add one line under "Learnings" in `AGENTS.md`. |
| The agent builds something you did not ask for | Add it to "Out of scope" in `SPEC.md`. |
| The planner stops without DONE | It has questions. Read "Questions for human" in `.factory/PROGRESS.md`. |
| You want an empty board | `bash harness/reset.sh`. Code on the current branch stays. |

Knobs: `MAX_ITERS` (default 40), `MAX_ATTEMPTS` before a task is blocked (3), `CLEAN_EVERY` merges (3), `AGENT_TIMEOUT` seconds per agent run (5400). When a role's log says the account hit a usage limit, the loop sleeps until the reset time printed in that log and runs the same role again. The wait is not a failed attempt.

Check a live run with `tail -f .factory/logs/loop.log` and `cat .factory/PROGRESS.md`.

## Going parallel

Do this only after the single loop runs cleanly. The roles, skills, and task format stay the same. Only the harness changes:

1. One worktree per worker: `git worktree add ../w1 -b task/T-004 main`.
2. One shared board at an absolute path every worktree uses (`FACTORY=/absolute/path/.factory`). A worker claims a task with `mv`. On one filesystem, `mv` is atomic.
3. Separate processes for workers, one or two evaluators, one planner, and one cleaner.
4. Merges stay serialized. Only evaluators merge to the base branch, behind `flock .factory/merge.lock`.
5. Add workers only while tasks stay independent. If several workers fail on the same broken thing, fix the task split first.

The parallel layout is not a script in this repo. The single-agent loop is `harness/loop.sh`.

## Files

```
AGENTS.md                         rules for every agent
CLAUDE.md                         @AGENTS.md, so Claude Code reads the same rules
LICENSE                           MIT
.env.example                      environment names the harness reads, no values
templates/SPEC.md                 blank spec (tracked)
SPEC.md                           your spec (gitignored; setup copies the template)
.agents/skills/*/SKILL.md         spec-interview, planner, worker, evaluator, cleaner
.claude/skills  .cursor/skills    symlinks to .agents/skills
harness/loop.sh                   the orchestrator
harness/agent.sh                  the only vendor adapter (claude / codex / cursor / mock)
harness/jev.sh                    optional TypeSafe client; the loop does not call it
harness/mock_agent.sh             fake agent for testing the loop
harness/setup.sh  reset.sh        seed the spec and the board; wipe the board
scripts/verify.sh                 tamper check plus the stack hook
scripts/verify.checks.example    commented TypeScript + Vite, Python, Go, and Rust checks
tests/acceptance/                 protected human-written tests (none shipped)
.factory/                         runtime board (gitignored)
```

## License

MIT. Copyright (c) 2026 LordOfTheTrees. See `LICENSE`.
