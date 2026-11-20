#!/usr/bin/env bash
# scripts/verify.sh — the single "is it done?" gate. Exit 0 means pass.
#
# Why it is protected: the evaluator can be talked into a pass, and a worker can
# be tempted to delete a failing test. This script is the check the loop trusts
# instead. Agents may run it. They may not edit it, and they may not edit
# tests/acceptance/ or scripts/verify.checks. When a base ref is passed, any diff
# that touches those paths or adds a skip/only marker fails the branch before review.
#
# The tamper check is stack-agnostic and stays intact. The CHECKS section is the
# only hook a fork fills in. It reads one command per line from
# scripts/verify.checks. A fresh fork has no such file, so this script passes
# and prints how to add checks. It does not assume a language or a package manager.
#
# usage:
#   ./scripts/verify.sh                 # project checks only
#   ./scripts/verify.sh origin/main     # also run the tamper check against that ref
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
BASE="${1:-}"
fail() { echo "ERROR: $*"; exit 1; }

# ---- 1. Tamper check: protected paths must be identical to base ----
PROTECTED=(scripts/verify.sh tests/acceptance scripts/verify.checks)
if [ -n "$BASE" ]; then
  git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null \
    || fail "tamper: base ref not found: $BASE"
  changed=$(git diff --name-only "$BASE" -- "${PROTECTED[@]}")
  [ -n "$changed" ] && fail "tamper: protected files changed: $changed"
  git diff "$BASE" -- . ':!scripts/verify.sh' | grep -qE '^\+.*(\.skip\(|\.only\(|@pytest\.mark\.skip|xit\(|xdescribe\()' \
    && fail "tamper: skipped/focused tests added"
fi

# ---- 2. CHECKS: stack-agnostic hook ---------------------------------------
# Forks configure this hook. Leave the tamper check above as it is.
#
# Put one shell command per line in scripts/verify.checks.
# Blank lines and lines whose first non-whitespace character is # are ignored.
# Each remaining line runs from the repo root with bash -c. The first non-zero
# exit fails the gate.
#
# A missing or empty file is a pass, with a notice, so a new fork does not fail
# before a stack exists. Commit scripts/verify.checks on the base branch before
# starting the loop. It is a protected path, so a task branch cannot weaken it.
#
# TypeScript + Vite example (scripts/verify.checks):
#   npm run --silent typecheck
#   npm run --silent lint
#   npm run --silent test
#   npm run --silent build
#
# See scripts/verify.checks.example.

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

run_project_checks() {
  local file="scripts/verify.checks"
  local line cmd ran=0
  if [ ! -f "$file" ]; then
    echo "NOTE: no project checks configured (scripts/verify.checks is missing)."
    echo "      A fresh fork passes here on purpose. The tamper check still runs"
    echo "      when you pass a base ref: ./scripts/verify.sh origin/main"
    echo "      Add scripts/verify.checks with one command per line."
    echo "      A TypeScript + Vite example is in scripts/verify.checks.example."
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    cmd="$(trim "$line")"
    case "$cmd" in
      ''|\#*) continue ;;
    esac
    ran=1
    echo "CHECK: $cmd"
    bash -c "$cmd" || fail "check failed: $cmd"
  done < "$file"
  if [ "$ran" -eq 0 ]; then
    echo "NOTE: scripts/verify.checks has no commands, so no project checks ran."
    echo "      Uncomment a stack example or add your own commands."
  fi
}

run_project_checks
echo "OK verify"
