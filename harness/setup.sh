#!/usr/bin/env bash
# harness/setup.sh — one-time setup after the kit is copied into a repo.
#
# Creates the gitignored board under .factory/, symlinks skills into the tool
# directories interactive sessions look at, and seeds SPEC.md from
# templates/SPEC.md when the working spec is missing. It does not overwrite an
# existing SPEC.md. The working spec is gitignored so this script's commit cannot
# publish it. .env is gitignored so local secrets stay untracked.
set -e
[ -d .git ] || { git init -q; git checkout -q -b main 2>/dev/null || true; }
mkdir -p .factory/board/todo .factory/board/doing .factory/board/done .factory/board/blocked \
         .factory/handoffs .factory/reviews .factory/logs
grep -qx '.factory/' .gitignore 2>/dev/null || echo '.factory/' >> .gitignore

# Working spec stays untracked. A missing SPEC.md is seeded from the pristine template.
[ -f SPEC.md ] || cp templates/SPEC.md SPEC.md

# Skills live once in .agents/skills. Symlink so interactive tools discover them natively.
# (The loop itself doesn't depend on this: it tells each agent the SKILL.md path directly.)
for d in .claude .cursor; do
  mkdir -p "$d"
  [ -e "$d/skills" ] || ln -s ../.agents/skills "$d/skills"
done

chmod +x harness/*.sh scripts/*.sh
if git add -A; then
  git commit -qm "agent factory setup" || true
fi
cat <<'EOF'
Setup done. Next:
  1. Write SPEC.md (or open Claude Code / Cursor and say: "use the spec-interview skill").
  2. Fill "Stack notes" in AGENTS.md. Commit.
  3. Dry run for free in a throwaway copy:  AGENT_CLI=mock MAX_ITERS=10 CLEAN_EVERY=1 harness/loop.sh
  4. Real run, in a VM/container:  AGENT_CLI=claude harness/loop.sh
EOF
