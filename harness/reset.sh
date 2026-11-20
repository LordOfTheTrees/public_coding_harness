#!/usr/bin/env bash
# harness/reset.sh — wipe coordination state between experiments.
#
# Deletes .factory/ and local task/* branches, then recreates the empty board.
# It does not change files on the current main branch. The product spec, the
# template, and the kit stay where they are. Use this when a run should start
# from an empty board without throwing away code the loop already merged.
set -e
cd "$(git rev-parse --show-toplevel)"
rm -rf .factory
for b in $(git for-each-ref --format='%(refname:short)' refs/heads/task/); do git branch -qD "$b"; done
mkdir -p .factory/board/todo .factory/board/doing .factory/board/done .factory/board/blocked \
         .factory/handoffs .factory/reviews .factory/logs
echo "board reset"
