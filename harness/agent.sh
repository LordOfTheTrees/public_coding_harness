#!/usr/bin/env bash
# harness/agent.sh — the only file that knows which coding-agent CLI you use.
#
# Why it is the only one: the rest of the kit is files and bash. loop.sh names a
# role and a prompt. It does not name Claude, Codex, or Cursor. Swapping tools is
# changing AGENT_CLI, not rewriting the loop.
#
# usage: harness/agent.sh <role> "<prompt>"
# env:   AGENT_CLI = claude | codex | cursor | mock      (default: claude)
#        MODEL_<ROLE>. loop.sh defaults planner/evaluator to grok-4.7 and
#        worker/cleaner to composer-2.5. Cursor bills those from its included
#        pool. Claude runs translate them to sonnet and claude-4.5-haiku.
#        Cursor's own default, with no --model flag, is Auto.
#        AGENT_TIMEOUT seconds per run (default 5400 = 90 min)
#
# CLI flags change often. If a run fails instantly, check `<cli> --help` and fix the line below.
# mock exists so the plumbing can be tested with no model and no API key.
set -uo pipefail
ROLE="$1"; PROMPT="$2"
CLI="${AGENT_CLI:-claude}"
ROLE_UP=$(printf '%s' "$ROLE" | tr '[:lower:]' '[:upper:]')
MODEL_VAR="MODEL_${ROLE_UP}"; MODEL="${!MODEL_VAR:-}"
TIMEOUT="${AGENT_TIMEOUT:-5400}"

# The loop's defaults are Cursor model ids. Claude Code and Codex do not
# accept those ids, so translate before the flag is added.
case "$CLI" in
  claude)
    case "$MODEL" in
      grok-4.7) MODEL=sonnet ;;
      composer-2.5|grok-4.5) MODEL=claude-4.5-haiku ;;
    esac ;;
  codex)
    case "$MODEL" in
      grok-*|composer-*) MODEL= ;;
    esac ;;
esac

# portable timeout (macOS has no `timeout` unless coreutils is installed as gtimeout)
if command -v timeout >/dev/null; then T="timeout $TIMEOUT"
elif command -v gtimeout >/dev/null; then T="gtimeout $TIMEOUT"
else T=""; fi

case "$CLI" in
  claude)
    # Claude Code headless mode. Skip-permissions = run ONLY in a container/VM.
    # Word-splitting on $T is intentional: it is empty or "timeout <seconds>".
    # shellcheck disable=SC2086
    exec $T claude -p "$PROMPT" --dangerously-skip-permissions ${MODEL:+--model "$MODEL"} ;;
  codex)
    # OpenAI Codex CLI non-interactive mode, sandboxed to the workspace.
    # shellcheck disable=SC2086
    exec $T codex exec --full-auto ${MODEL:+-m "$MODEL"} "$PROMPT" ;;
  cursor)
    # Cursor CLI (binary may be `agent` or `cursor-agent` depending on version).
    # --force lets it actually write files in print mode.
    # --trust is required in print mode; otherwise the CLI waits for a prompt
    # the harness cannot answer. --model comes from MODEL_<ROLE>.
    # shellcheck disable=SC2086
    exec $T agent -p --force --trust ${MODEL:+--model "$MODEL"} "$PROMPT" ;;
  mock)
    # Fake agent for testing the plumbing without calling a model.
    exec "$(dirname "$0")/mock_agent.sh" "$ROLE" "$PROMPT" ;;
  *)
    echo "Unknown AGENT_CLI=$CLI" >&2; exit 2 ;;
esac
