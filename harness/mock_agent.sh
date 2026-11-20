#!/usr/bin/env bash
# harness/mock_agent.sh — a fake coding agent for the loop, with no model and no key.
#
# Why it exists: the first thing to prove is the plumbing, not the model. This
# stand-in writes the same files a real role would write, so loop.sh can be run
# end to end. The planner creates T-001-mock and T-002-mock, the worker writes a
# handoff, and the evaluator fails T-002 once so the retry path is actually taken.
# Run it in a throwaway copy: AGENT_CLI=mock harness/loop.sh
set -u
ROLE="$1"; F="${FACTORY:-.factory}"
case "$ROLE" in
  planner)
    board_has_md=0
    for board_md in "$F"/board/*/*.md; do
      [ -e "$board_md" ] || break
      board_has_md=1
      break
    done
    unset board_md
    if [ "$board_has_md" -eq 0 ]; then
      for n in 001 002; do
        printf '# T-%s: mock task\nscope: .factory/mock-build/\n\n## Acceptance\n- [ ] file exists\n' "$n" \
          > "$F/board/todo/T-$n-mock.md"
      done
      echo "# PROGRESS (mock)" > "$F/PROGRESS.md"
    else
      echo DONE > "$F/STATUS"
    fi ;;
  worker)
    mkdir -p "$F/mock-build" && echo "built $TASK_ID $(date)" >> "$F/mock-build/$TASK_ID.txt"
    printf 'STATUS: DONE\n## What I did\nmock\n' > "$F/handoffs/$TASK_ID.md" ;;
  evaluator)
    if [ "$TASK_ID" = "T-002-mock" ] && [ ! -f "$F/reviews/.seen-$TASK_ID" ]; then
      touch "$F/reviews/.seen-$TASK_ID"
      printf 'VERDICT: FAIL\n## Required fixes\n1. mock rejection to test retry\n' > "$F/reviews/$TASK_ID.md"
    else
      printf 'VERDICT: PASS\n' > "$F/reviews/$TASK_ID.md"
    fi ;;
  cleaner)
    echo "mock cleanup $(date)" > "$F/handoffs/cleanup-$(date +%s).md" ;;
esac
echo "[mock $ROLE] ok"
