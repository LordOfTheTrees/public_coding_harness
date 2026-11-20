# Acceptance tests

This directory is the human-written oracle.

`scripts/verify.sh` treats `tests/acceptance/` as a protected path, along with
itself and `scripts/verify.checks`. Agents may run the verifier. They may not
edit, skip, or weaken anything here.

Pass a base ref to turn that protection on:

```bash
./scripts/verify.sh origin/main
```

A branch that changes a file in this directory, or that adds a skipped or
focused test anywhere else, fails before review.

Put the checks a product must keep satisfying in this directory, in whatever
form the stack uses: a test file, a script, or a fixture. Commit them on the
base branch before starting the loop. The kit ships no product tests. A fresh
fork has nothing here to satisfy except this note.
