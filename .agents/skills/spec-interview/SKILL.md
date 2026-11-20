---
name: spec-interview
description: Turn a rough product idea into a complete SPEC.md that autonomous agents can build from. Use whenever the user wants to start a new project, write or improve SPEC.md, define an MVP, or says "help me spec this". Run this interactively BEFORE starting the agent loop.
---

# Spec interview

Goal: produce a SPEC.md specific enough that a planner agent can split it into tasks and an
evaluator can check each one without asking a human. The blank original is templates/SPEC.md.
Copy it to SPEC.md if SPEC.md is missing. Write SPEC.md only. Never edit the template.
SPEC.md is gitignored, so the kit clone stays pristine.

## Process
1. Ask for the idea in one paragraph if not given.
2. Interview in short rounds (max 3 questions per round). Cover, in order:
   - Who is the user and what is the single most important thing they do?
   - The 3–7 user stories for the MVP. Push back if there are more than 7; cut scope.
   - For each story: what would a tester SEE that proves it works? (becomes acceptance criteria)
   - Stack and hosting. If the user has no preference, propose a boring default and confirm.
   - Hard constraints and things explicitly out of scope.
3. Write SPEC.md using the template sections. Rules:
   - Every acceptance criterion is observable from outside the code (HTTP response, UI behavior, CLI output).
   - No vague words ("fast", "nice", "robust") without a number or example.
   - The out-of-scope list is mandatory. Agents drift into anything not forbidden.
4. Fill the "Stack notes" section of AGENTS.md (install, dev server, conventions).
5. Put the real check commands in scripts/verify.checks, one per line. scripts/verify.sh runs that file. Do not change the tamper check at the top of scripts/verify.sh. A commented TypeScript + Vite example is in scripts/verify.checks.example.
6. Show the user the final SPEC.md and ask them to confirm before starting the loop.
