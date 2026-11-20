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
#   -> optional Jev "keep building?" check after a merge (fail open)
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
#         JEV_GATE=on|off (default on when TYPESAFE_API_KEY is set)
#         JEV_MODE=enforce|log (default log)  JEV_DONE_AUTHORITY=both|planner|jev (default both)
#         JEV_CONTINUE_THRESHOLD (default 0.5)  JEV_MOCK_NOUL (no-network stub)
#         JEV_STATE_TOKEN_BUDGET (default 24000)  JEV_EXTEND_ITERS (default 0)
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
open_count() {
  local n=0 f
  for f in "$B/todo/"*.md "$B/doing/"*.md; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}
latest_match() { # <dir> <name-pattern>
  find "$1" -name "$2" -printf '%T@\t%p\n' 2>/dev/null | sort -n | tail -n 1 | cut -f2-
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

# One decision for every Jev check. Prints continue, stop, replan,
# stop_disagree, extend, or record. Log mode, a missing key, a Jev error,
# and authority=planner all fall back to the planner: DONE stops the loop,
# and a merge or the iteration cap does not.
jev_decide() { # <merge|planner_done|cap>
  local situation="$1" mode authority open_n extend_n done_by_jev
  mode="${JEV_MODE:-log}"
  authority="${JEV_DONE_AUTHORITY:-both}"
  case "$authority" in
    both|planner|jev) ;;
    *) authority="both" ;;
  esac
  case "$mode" in
    enforce) ;;
    *) mode="log" ;;
  esac
  open_n=$(open_count)
  case "${JEV_EXTEND_ITERS:-0}" in
    ''|*[!0-9]*) extend_n=0 ;;
    *) extend_n="${JEV_EXTEND_ITERS:-0}" ;;
  esac
  if [ "${JEV_HAVE:-0}" != 1 ] || [ "$mode" != "enforce" ] || [ "$authority" = "planner" ]; then
    case "$situation" in
      planner_done) printf '%s\n' stop ;;
      cap) printf '%s\n' record ;;
      *) printf '%s\n' continue ;;
    esac
    return 0
  fi
  done_by_jev=0
  if python3 - "$JEV_NOUL" "$JEV_THRESHOLD" <<'PY'
import sys
sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)
PY
  then
    done_by_jev=1
  fi
  case "$situation" in
    merge)
      if [ "$authority" = "jev" ] && [ "$done_by_jev" = 1 ] && [ "$open_n" -eq 0 ]; then
        printf '%s\n' stop
      else
        printf '%s\n' continue
      fi
      ;;
    planner_done)
      if [ "$open_n" -gt 0 ]; then
        printf '%s\n' continue
      elif [ "$authority" = "jev" ]; then
        if [ "$done_by_jev" = 1 ]; then printf '%s\n' stop; else printf '%s\n' continue; fi
      elif [ "$done_by_jev" = 1 ]; then
        printf '%s\n' stop
      elif [ "${jev_replanned:-0}" = 1 ]; then
        printf '%s\n' stop_disagree
      else
        printf '%s\n' replan
      fi
      ;;
    cap)
      if [ "$done_by_jev" = 0 ] && [ "$extend_n" -gt 0 ] && [ "${jev_extended:-0}" = 0 ]; then
        printf '%s\n' extend
      else
        printf '%s\n' record
      fi
      ;;
    *)
      printf '%s\n' continue
      ;;
  esac
}

# Build the Jev request and parse a noul. Sets JEV_HAVE=1 on success.
# Returns 1 when the gate is off, no key is available, or Jev fails.
jev_consult() { # [merged-task-id]
  local task="${1:-}" review verify outline diffstat cuts req resp noul base_sha
  JEV_HAVE=0
  JEV_NOUL=""
  JEV_THRESHOLD="${JEV_CONTINUE_THRESHOLD:-0.5}"
  case "${JEV_GATE:-}" in
    off|OFF) return 1 ;;
  esac
  if ! "$HERE/jev.sh" configured >/dev/null 2>&1; then
    return 1
  fi
  if [ "${AGENT_CLI:-}" = "mock" ] && [ -z "${JEV_MOCK_NOUL:-}" ]; then
    return 1
  fi

  if [ -n "$task" ] && [ -f "$FACTORY/reviews/$task.md" ]; then
    review="$FACTORY/reviews/$task.md"
  else
    review=$(latest_match "$FACTORY/reviews" '*.md')
  fi
  verify=$(latest_match "$FACTORY/logs" 'verify-*.log')
  outline=$(mktemp)
  diffstat=$(mktemp)
  cuts=$(mktemp)
  "$HERE/outline.sh" > "$outline" 2>>"$FACTORY/logs/jev-gate.log" || true
  base_sha=""
  if [ -f "$FACTORY/logs/jev-last-sha" ]; then
    base_sha=$(cat "$FACTORY/logs/jev-last-sha")
  fi
  if [ -n "$base_sha" ]; then
    git diff --stat "$base_sha" HEAD > "$diffstat" 2>/dev/null || true
  fi
  req="$FACTORY/logs/jev-last-request.json"
  resp="$FACTORY/logs/jev-last-response.json"
  if ! python3 - "$PWD/SPEC.md" "$B" "$review" "$verify" "$outline" "$diffstat" "${JEV_STATE_TOKEN_BUDGET:-24000}" "$cuts" > "$req" <<'PY'
import json, os, sys
(spec_path, board, review, verify_log, outline_path, diff_path, budget_s, cuts_path) = sys.argv[1:]

def read(path, limit=None):
    if not path or not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8", errors="replace") as handle:
        data = handle.read()
    if limit is not None and len(data) > limit:
        data = data[-limit:]
    return data.strip()

def titles(dirname, limit=40):
    found = []
    path = os.path.join(board, dirname)
    if not os.path.isdir(path):
        return found
    for name in sorted(os.listdir(path)):
        if not name.endswith(".md"):
            continue
        title = name[:-3]
        try:
            with open(os.path.join(path, name), encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    line = line.strip()
                    if line:
                        title = line.lstrip("#").strip() or title
                        break
        except OSError:
            pass
        found.append(title[:200])
        if len(found) >= limit:
            break
    return found

def listing(label, items):
    if not items:
        return label + ":\n- (none)"
    return label + ":\n" + "\n".join("- " + item for item in items)

try:
    budget = int(budget_s)
except ValueError:
    budget = 24000
if budget < 1:
    budget = 1
# State plus the question must stay under Jev's 32k-token limit. 24000 leaves headroom.
if budget > 30000:
    budget = 30000
budget_chars = budget * 4

spec = read(spec_path) or "(SPEC.md missing)"
board_text = "\n\n".join([
    listing("Done", titles("done")),
    listing("Open", titles("todo") + titles("doing")),
    listing("Failed", titles("blocked")),
    "Latest evaluator verdict:\n" + (read(review, 8000) or "(none)"),
])
sections = [
    ("spec", "SPEC.md:\n" + spec),
    ("board", "Board:\n" + board_text),
    ("verify", "Latest verify.sh result:\n" + (read(verify_log, 8000) or "(no verify.sh result yet)")),
    ("outline", "Code outline (what exists; verify.sh says whether it works):\n" + (read(outline_path) or "(no outline)")),
    ("diff", "Diff stat since the last check:\n" + (read(diff_path) or "(no diff since the last check)")),
]
kept = []
used = 0
cut = []
outline_complete = False
for index, (name, text) in enumerate(sections):
    block = text.strip() + "\n\n"
    if used + len(block) <= budget_chars:
        kept.append(block)
        used += len(block)
        if name == "outline":
            outline_complete = True
        continue
    room = budget_chars - used
    cut.append(name + (" partial" if room > 80 else " dropped"))
    if room > 80:
        piece = block[:room].rstrip() + "\n…[trimmed]\n\n"
        kept.append(piece)
        used = budget_chars
        if name == "outline":
            outline_complete = False
    for later_name, _later in sections[index + 1:]:
        cut.append(later_name + " dropped")
    break
state = "".join(kept).rstrip() + "\n"
if not outline_complete:
    notice = "\nOutline truncated.\n"
    if len(state) + len(notice) > budget_chars:
        state = state[: max(0, budget_chars - len(notice))].rstrip() + "\n"
    state += notice
tokens = (len(state) + 3) // 4
with open(cuts_path, "w", encoding="utf-8") as handle:
    handle.write(f"chars={len(state)} tokens={tokens} budget_tokens={budget}\n")
    for item in cut:
        handle.write("cut " + item + "\n")
json.dump({
    "state": state,
    "questions": {
        "keep_building": {
            "type": "noul",
            "instructions": "Does this project still need more building to meet the intent in SPEC.md? Y/N.",
        }
    },
}, sys.stdout)
sys.stdout.write("\n")
PY
  then
    rm -f "$outline" "$diffstat" "$cuts"
    log "   jev gate: could not build the request; continuing (fail open)"
    return 1
  fi
  if [ -f "$cuts" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] && log "   jev state: $line"
    done < "$cuts"
  fi
  rm -f "$outline" "$diffstat" "$cuts"

  if ! "$HERE/jev.sh" < "$req" > "$resp" 2>>"$FACTORY/logs/jev-gate.log"; then
    printf '%s noul= decision=continue reason=jev error (fail open)\n' "$(date '+%F %T')" >> "$FACTORY/logs/jev-gate.log"
    log "   jev gate: Jev failed; continuing (fail open)"
    return 1
  fi
  git rev-parse HEAD > "$FACTORY/logs/jev-last-sha" 2>/dev/null || true
  if ! noul=$(python3 - "$resp" "$JEV_THRESHOLD" <<'PY'
import json, sys
try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
    noul = payload.get("answers", {}).get("keep_building", {}).get("noul")
    threshold = float(sys.argv[2])
except (OSError, ValueError, json.JSONDecodeError):
    sys.exit(2)
if not isinstance(noul, (int, float)) or isinstance(noul, bool):
    sys.exit(2)
print(f"{float(noul):.6f} {threshold:.6f}")
PY
  ); then
    printf '%s noul= decision=continue reason=unreadable noul (fail open)\n' "$(date '+%F %T')" >> "$FACTORY/logs/jev-gate.log"
    log "   jev gate: unreadable noul; continuing (fail open)"
    return 1
  fi
  JEV_HAVE=1
  JEV_NOUL="${noul%% *}"
  JEV_THRESHOLD="${noul##* }"
  return 0
}

jev_outcome_word() {
  if [ "${JEV_HAVE:-0}" != 1 ]; then
    printf '%s\n' unavailable
    return 0
  fi
  if python3 - "$JEV_NOUL" "$JEV_THRESHOLD" <<'PY'
import sys
sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)
PY
  then
    printf '%s\n' "likely done"
  else
    printf '%s\n' unfinished
  fi
}

jev_note() { # <situation> <action>
  local situation="$1" action="$2" label
  label=$(jev_outcome_word)
  printf '%s situation=%s noul=%s threshold=%s label=%s mode=%s authority=%s action=%s open=%s\n' \
    "$(date '+%F %T')" "$situation" "${JEV_NOUL:-}" "${JEV_THRESHOLD:-}" "$label" \
    "${JEV_MODE:-log}" "${JEV_DONE_AUTHORITY:-both}" "$action" "$(open_count)" \
    >> "$FACTORY/logs/jev-gate.log"
  log "   jev gate: $situation label=$label noul=${JEV_NOUL:-none} action=$action open=$(open_count)"
}

jev_write_final() {
  printf '%s\n' "$1" >> "$FACTORY/logs/jev-final.txt"
  log "   jev final: $1"
}

# Return 0 to keep the batch going, 1 to stop it.
handle_planner_done() {
  local action
  jev_consult "" || true
  action=$(jev_decide planner_done)
  if [ "${JEV_HAVE:-0}" = 1 ]; then
    jev_note planner_done "$action"
  fi
  case "$action" in
    stop)
      return 1 ;;
    stop_disagree)
      jev_write_final "disagreement: planner said DONE, Jev unfinished noul=${JEV_NOUL:-unknown}"
      return 1 ;;
    replan)
      jev_replanned=1
      rm -f "$FACTORY/STATUS"
      log "   jev gate: planner DONE, Jev unfinished; one replan"
      run_role planner "Jev's keep-building verdict is unfinished, noul=${JEV_NOUL:-unknown}, threshold ${JEV_THRESHOLD:-0.5}. The question was: Does this project still need more building to meet the intent in SPEC.md? Y/N. Write the next tasks if the spec still needs work. Write DONE only if you still believe the spec is met. This is the one replan."
      if is_done; then
        jev_write_final "disagreement: planner said DONE, Jev unfinished noul=${JEV_NOUL:-unknown}"
        log "   jev gate: planner said DONE again; stopping and recording the disagreement"
        return 1
      fi
      return 0 ;;
    *)
      rm -f "$FACTORY/STATUS"
      return 0 ;;
  esac
}

jev_after_merge() { # <task-id>
  local action
  jev_consult "$1" || true
  action=$(jev_decide merge)
  if [ "${JEV_HAVE:-0}" = 1 ]; then
    jev_note merge "$action"
  fi
  if [ "$action" = "stop" ]; then
    printf '%s\n' "Stopped after $1. Jev noul ${JEV_NOUL:-unknown} is below threshold ${JEV_THRESHOLD:-0.5} and no planned tasks are open." > "$FACTORY/logs/jev-stop.txt"
    log "   jev gate: STOP. Jev says likely done and no planned tasks are open"
    return 1
  fi
  return 0
}

jev_on_cap() {
  local label action
  if ! jev_consult ""; then
    log "   jev gate: iteration cap reached; no Jev verdict (fail open)"
    return 0
  fi
  label=$(jev_outcome_word)
  jev_write_final "$label noul=${JEV_NOUL}"
  action=$(jev_decide cap)
  jev_note cap "$action"
  if [ "$action" = "extend" ]; then
    jev_extended=1
    log "   jev gate: granting one extension of ${JEV_EXTEND_ITERS} iterations"
    if run_batch "$JEV_EXTEND_ITERS"; then
      if jev_consult ""; then
        label=$(jev_outcome_word)
        jev_write_final "$label noul=${JEV_NOUL}"
      else
        jev_write_final "unavailable"
      fi
      if [ "${JEV_HAVE:-0}" = 1 ]; then
        jev_note cap record
      fi
      log "   jev gate: extension already used; stopping at the cap"
    fi
  fi
}

reject() { # <id> <reason>   append feedback, send back to todo or block after MAX_ATTEMPTS
  local f="$B/doing/$1.md" n
  n=$(( $(grep -c '^## Attempt ' "$f") + 1 ))
  printf '\n## Attempt %s feedback\n%s\n' "$n" "$2" >> "$f"
  if [ "$n" -ge "$MAX_ATTEMPTS" ]; then mv "$f" "$B/blocked/"; log "   xx $1 BLOCKED after $n attempts"
  else mv "$f" "$B/todo/"; log "   <- $1 back to todo (attempt $n rejected)"; fi
}

# Run N iterations. Return 0 when the cap is reached, 1 when the batch stops early.
run_batch() {
  local n="$1" i
  batch_stop=0
  for i in $(seq 1 "$n"); do
    TASK_ID=""
    merged_task=""
    if is_done; then
      handle_planner_done || { batch_stop=1; break; }
    fi

    if [ -z "$(next_task)" ]; then
      log "[$i] todo empty -> planner"
      run_role planner "Write the next batch of tasks into $B/todo/."
      commit "planner: notes"; discard
      if is_done; then
        handle_planner_done || { batch_stop=1; break; }
      fi
      if [ -z "$(next_task)" ]; then
        log "Planner made no tasks and didn't declare DONE. Read $FACTORY/PROGRESS.md. Stopping."
        batch_stop=1
        break
      fi
    fi

    export TASK_ID; TASK_ID=$(next_task)
    log "[$i] $TASK_ID"
    mv "$B/todo/$TASK_ID.md" "$B/doing/"
    BR="task/$TASK_ID"
    TF="$B/doing/$TASK_ID.md"; HO="$FACTORY/handoffs/$TASK_ID.md"; RV="$FACTORY/reviews/$TASK_ID.md"

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

    # A failing verify.sh rejects the task and blocks the merge. Jev does not run
    # on this path and cannot waive a failed check.
    if ! ./scripts/verify.sh "$MAIN" > "$FACTORY/logs/verify-$TASK_ID.log" 2>&1; then
      to_main
      reject "$TASK_ID" "scripts/verify.sh failed. Last output:
\`\`\`
$(tail -n 30 "$FACTORY/logs/verify-$TASK_ID.log")
\`\`\`"
      continue
    fi

    run_role evaluator "Task file: $TF . Worker handoff: $HO . See the changes with: git diff $MAIN...HEAD . Write your verdict to: $RV ."
    if head -n1 "$RV" 2>/dev/null | grep -q '^VERDICT: PASS'; then
      to_main
      if git merge -q --no-ff -m "merge $TASK_ID" "$BR"; then
        git branch -qD "$BR"; mv "$TF" "$B/done/"; merged=$((merged+1)); merged_task="$TASK_ID"; log "   ✓ $TASK_ID merged"
      else
        git merge --abort; reject "$TASK_ID" "Passed review but conflicted when merging into $MAIN. Redo it on top of current code."
      fi
    else
      to_main
      reject "$TASK_ID" "Evaluator review:
$(cat "$RV" 2>/dev/null || echo 'Evaluator wrote no review.')"
    fi

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

    if [ -n "$merged_task" ]; then
      jev_after_merge "$merged_task" || { batch_stop=1; break; }
    fi
  done
  [ "$batch_stop" -eq 0 ]
}

git checkout -q "$MAIN" || { echo "Commit or stash your changes first."; exit 1; }
clean_base=$(git rev-parse HEAD); merged=0
jev_replanned=0
jev_extended=0
log "=== loop start: AGENT_CLI=${AGENT_CLI:-claude} main=$MAIN mode=${JEV_MODE:-log} authority=${JEV_DONE_AUTHORITY:-both} ==="

if run_batch "$MAX_ITERS"; then
  jev_on_cap
fi

log "=== stopped. done: $(count_md "$B/done")  blocked: $(count_md "$B/blocked")  todo: $(count_md "$B/todo") ==="
if [ -f "$FACTORY/logs/jev-final.txt" ]; then
  printf 'jev final: %s\n' "$(tail -n 1 "$FACTORY/logs/jev-final.txt")"
fi
