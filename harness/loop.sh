#!/usr/bin/env bash
# harness/loop.sh — one-agent-at-a-time orchestrator.
#
# Why this file exists: planning, coding, and review are judgments, so they belong
# to whichever coding agent harness/agent.sh launches. Choosing the next task,
# isolating it on branch task/<id>, running scripts/verify.sh, reading the
# evaluator's first line, merging, or sending the task back are mechanisms. They
# must happen the same way on every machine, so they are bash. Agents are told
# not to run git. A confused model must not be able to merge, reset, or push.
#
# Cycle:
#   planner (when todo is empty) -> worker on branch task/<id> -> verify.sh
#   -> evaluator -> merge to main, or append feedback and return the task
#   -> cleaner every CLEAN_EVERY merges, reverted if verify.sh fails
#
# The board lives in .factory/, which is gitignored. That state is coordination,
# not part of the kit a clone should receive. Pass/fail is the first line of the
# review file (VERDICT: PASS or VERDICT: FAIL). The loop does not interpret prose.
#
# usage:  harness/loop.sh
# env:    AGENT_CLI=claude|codex|cursor|mock   MAX_ITERS=40   MAX_ATTEMPTS=3   CLEAN_EVERY=3
#         MODEL_PLANNER, MODEL_WORKER, MODEL_EVALUATOR, MODEL_CLEANER
#         Defaults: planner and evaluator grok-4.7, worker and cleaner composer-2.5.
#         Those are Cursor-pool models. Claude runs map them back to sonnet and Haiku.
#         A usage-limit message sleeps until the reset time and retries the same
#         role. That wait does not count as a failed attempt.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
HERE="$PWD/harness"
export FACTORY="$PWD/.factory"
B="$FACTORY/board"
MAIN="${MAIN_BRANCH:-$(git symbolic-ref --short HEAD)}"
MAX_ITERS="${MAX_ITERS:-40}"; MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"; CLEAN_EVERY="${CLEAN_EVERY:-3}"
# Strong model plans and judges. Cheap model writes code and does small cleanups.
# grok-4.7 is the Sonnet-class model on Cursor's included pool. composer-2.5 is
# the cheap coder in that same pool. Grok 4.5 is billed at the same rate as 4.7.
# An explicit MODEL_* in the environment still wins.
: "${MODEL_PLANNER:=grok-4.7}"
: "${MODEL_EVALUATOR:=grok-4.7}"
: "${MODEL_WORKER:=composer-2.5}"
: "${MODEL_CLEANER:=composer-2.5}"
export MODEL_PLANNER MODEL_EVALUATOR MODEL_WORKER MODEL_CLEANER
mkdir -p "$B"/{todo,doing,done,blocked} "$FACTORY"/{handoffs,reviews,logs}

log()       { echo "[$(date '+%F %T')] $*" | tee -a "$FACTORY/logs/loop.log"; }
commit()    { git add -A; git diff --cached --quiet || git commit -qm "$1"; }
discard()   { git reset -q --hard; git clean -fdq; }          # ignored files (.factory) survive
to_main()   { discard; git checkout -q "$MAIN"; }
is_done()   { [ -f "$FACTORY/STATUS" ] && grep -q DONE "$FACTORY/STATUS"; }
next_task() {
  local f base
  for f in "$B/todo/"*.md; do
    [ -e "$f" ] || return 0
    base="${f##*/}"
    printf '%s\n' "${base%.md}"
    return 0
  done
}
count_md() {
  local d="$1" f n=0
  for f in "$d"/*.md; do
    [ -e "$f" ] || break
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# Prints seconds to sleep when the log is a usage cap, and exits 1 otherwise.
# A parsed "resets 10pm (America/New_York)" waits until that clock. Otherwise
# the wait is 20 minutes. Never longer than 6 hours.
quota_sleep_seconds() {
  python3 - "$1" <<'PY'
import datetime, re, sys
from zoneinfo import ZoneInfo
text = open(sys.argv[1], errors="replace").read()
if not re.search(r"(hit your .{0,40}limit|usage limit|rate limit|too many requests)", text, re.I):
    sys.exit(1)
secs = 20 * 60
m = re.search(r"resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*\(([^)]+)\)", text, re.I)
if m:
    hour = int(m.group(1)) % 12
    if m.group(3).lower() == "pm":
        hour += 12
    minute = int(m.group(2) or 0)
    try:
        tz = ZoneInfo(m.group(4).strip())
    except Exception:
        tz = datetime.datetime.now().astimezone().tzinfo
    now = datetime.datetime.now(tz)
    target = now.replace(hour=hour, minute=minute, second=30, microsecond=0)
    if target <= now:
        target += datetime.timedelta(days=1)
    secs = int((target - now).total_seconds())
secs = max(60, min(secs, 6 * 3600))
print(secs)
PY
}

run_role() { # <role> <extra prompt>
  local role="$1" extra="$2"
  local logf prompt wait
  prompt="You are the $(printf '%s' "$role" | tr '[:lower:]' '[:upper:]') agent in an automated build loop. \
Read .agents/skills/$role/SKILL.md and AGENTS.md, then follow the skill exactly. \
Coordination files live in $FACTORY. $extra \
Never run git commit, checkout, merge, reset, or push; the harness handles git. When finished, stop."
  while true; do
    logf="$FACTORY/logs/$(date +%Y%m%d-%H%M%S)-$role${TASK_ID:+-$TASK_ID}.log"
    log "   -> $role (log: ${logf##*/})"
    "$HERE/agent.sh" "$role" "$prompt" > "$logf" 2>&1 || log "   !! $role exited non-zero, see log"
    if wait=$(quota_sleep_seconds "$logf"); then
      log "   .. usage limit. Sleeping ${wait}s, then retrying $role. This does not count as an attempt."
      sleep "$wait"
      continue
    fi
    break
  done
}

reject() { # <id> <reason>   append feedback, send back to todo or block after MAX_ATTEMPTS
  local f="$B/doing/$1.md" n
  n=$(( $(grep -c '^## Attempt ' "$f") + 1 ))
  printf '\n## Attempt %s feedback\n%s\n' "$n" "$2" >> "$f"
  if [ "$n" -ge "$MAX_ATTEMPTS" ]; then mv "$f" "$B/blocked/"; log "   xx $1 BLOCKED after $n attempts"
  else mv "$f" "$B/todo/"; log "   <- $1 back to todo (attempt $n rejected)"; fi
}

git checkout -q "$MAIN" || { echo "Commit or stash your changes first."; exit 1; }
clean_base=$(git rev-parse HEAD); merged=0
log "=== loop start: AGENT_CLI=${AGENT_CLI:-claude} main=$MAIN ==="

for i in $(seq 1 "$MAX_ITERS"); do
  TASK_ID=""
  is_done && { log "Planner declared DONE."; break; }

  # ---- PLAN (only when nothing is ready) ----
  if [ -z "$(next_task)" ]; then
    log "[$i] todo empty -> planner"
    run_role planner "Write the next batch of tasks into $B/todo/."
    commit "planner: notes"; discard
    is_done && { log "Planner declared DONE."; break; }
    [ -z "$(next_task)" ] && { log "Planner made no tasks and didn't declare DONE. Read $FACTORY/PROGRESS.md. Stopping."; break; }
  fi

  export TASK_ID; TASK_ID=$(next_task)
  log "[$i] $TASK_ID"
  mv "$B/todo/$TASK_ID.md" "$B/doing/"
  BR="task/$TASK_ID"
  TF="$B/doing/$TASK_ID.md"; HO="$FACTORY/handoffs/$TASK_ID.md"; RV="$FACTORY/reviews/$TASK_ID.md"

  # ---- WORK on an isolated branch (retries reuse the branch, rebuilt on top of main) ----
  if git show-ref -q --verify "refs/heads/$BR"; then
    git checkout -q "$BR"
    if ! git merge -q --no-edit "$MAIN" >/dev/null 2>&1; then
      git merge --abort; git checkout -q "$MAIN"; git branch -qD "$BR"; git checkout -q -b "$BR"
    fi
  else
    git checkout -q -b "$BR"
  fi
  rm -f "$HO" "$RV"
  run_role worker "Your task file: $TF . Write your handoff to: $HO ."
  commit "$TASK_ID: worker attempt"

  if [ ! -f "$HO" ]; then to_main; reject "$TASK_ID" "Worker wrote no handoff (crashed or timed out). Finish the task and write the handoff."; continue; fi
  if head -n1 "$HO" | grep -q BLOCKED; then to_main; mv "$TF" "$B/blocked/"; log "   xx worker reported BLOCKED"; continue; fi

  # ---- GATE 1: deterministic checks ----
  if ! ./scripts/verify.sh "$MAIN" > "$FACTORY/logs/verify-$TASK_ID.log" 2>&1; then
    to_main
    reject "$TASK_ID" "scripts/verify.sh failed. Last output:
\`\`\`
$(tail -n 30 "$FACTORY/logs/verify-$TASK_ID.log")
\`\`\`"
    continue
  fi

  # ---- GATE 2: skeptical evaluator ----
  run_role evaluator "Task file: $TF . Worker handoff: $HO . See the changes with: git diff $MAIN...HEAD . Write your verdict to: $RV ."
  if head -n1 "$RV" 2>/dev/null | grep -q '^VERDICT: PASS'; then
    to_main
    if git merge -q --no-ff -m "merge $TASK_ID" "$BR"; then
      git branch -qD "$BR"; mv "$TF" "$B/done/"; merged=$((merged+1)); log "   ✓ $TASK_ID merged"
    else
      git merge --abort; reject "$TASK_ID" "Passed review but conflicted when merging into $MAIN. Redo it on top of current code."
    fi
  else
    to_main
    reject "$TASK_ID" "Evaluator review:
$(cat "$RV" 2>/dev/null || echo 'Evaluator wrote no review.')"
  fi

  # ---- CLEAN every N merges; reverted automatically if it breaks anything ----
  if [ "$merged" -ge "$CLEAN_EVERY" ]; then
    TASK_ID=""; pre=$(git rev-parse HEAD)
    run_role cleaner "Recently merged work: git diff $clean_base..HEAD . Write your summary to: $FACTORY/handoffs/cleanup-$i.md ."
    if ./scripts/verify.sh "$pre" > "$FACTORY/logs/verify-cleanup-$i.log" 2>&1; then
      commit "cleaner: pass $i"; log "   ✓ cleanup committed"
    else
      discard; log "   xx cleanup broke verify.sh; reverted"
    fi
    clean_base=$(git rev-parse HEAD); merged=0
  fi
done

log "=== stopped. done: $(count_md "$B/done")  blocked: $(count_md "$B/blocked")  todo: $(count_md "$B/todo") ==="
