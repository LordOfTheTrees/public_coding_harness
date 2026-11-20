#!/usr/bin/env bash
# harness/jev.sh — call TypeSafe Jev over HTTP, with the key kept out of git.
#
# Jev is a System One model. You send a state and typed questions; it returns a
# yes/no probability (noul), a choice, or a score. It does not write code, hold a
# conversation, or replace AGENT_CLI. The coding agent stays in harness/agent.sh.
# This script is bash plus Python's standard library so the same call works on any
# machine that has Python 3, with no vendor SDK to install.
#
# The key is TYPESAFE_API_KEY. A value already exported in the shell wins, which
# lets CI inject the key without a file. Otherwise the script reads that one
# assignment from a gitignored .env in the repo root. The file is parsed as
# KEY=VALUE, not executed, so a line in it cannot run a command. The value is
# never logged or placed on a command line.
#
#   .env:  TYPESAFE_API_KEY=...
#   harness/jev.sh test              # one canned request; prints the judgment only
#   harness/jev.sh < request.json    # raw System One body on stdin; prints JSON
#
# Optional: JEV_MODEL (default jev-latest), TYPESAFE_API_URL
#   (default https://api.typesafe.ai/v1/systemone)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
if [ -z "${TYPESAFE_API_KEY:-}" ] && [ -f "$ROOT/.env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    case "$line" in
      ''|\#*) continue ;;
      export\ *) line="$(trim "${line#export }")" ;;
    esac
    key="$(trim "${line%%=*}")"
    [ "$key" = "TYPESAFE_API_KEY" ] || continue
    val="$(trim "${line#*=}")"
    if [ "${#val}" -ge 2 ]; then
      first="${val%"${val#?}"}"
      last="${val#"${val%?}"}"
      if [ "$first" = "$last" ] && { [ "$first" = '"' ] || [ "$first" = "'" ]; }; then
        val="${val#?}"
        val="${val%?}"
      fi
    fi
    TYPESAFE_API_KEY="$val"
  done < "$ROOT/.env"
fi

if [ -z "${TYPESAFE_API_KEY:-}" ]; then
  echo "TYPESAFE_API_KEY is not set. Put it in .env at the repo root, or export it in this shell. Do not commit it or paste it into a prompt." >&2
  exit 2
fi
export TYPESAFE_API_KEY

export JEV_MODEL="${JEV_MODEL:-jev-latest}"
export TYPESAFE_API_URL="${TYPESAFE_API_URL:-https://api.typesafe.ai/v1/systemone}"
MODE="${1:-ask}"

exec python3 - "$MODE" <<'PY'
import json, os, sys, urllib.error, urllib.request

mode = sys.argv[1]
key = os.environ["TYPESAFE_API_KEY"]
url = os.environ["TYPESAFE_API_URL"]
model = os.environ["JEV_MODEL"]

if mode == "test":
    body = {
        "model": model,
        "state": "I was charged twice for my subscription this month. Please refund the extra charge.",
        "questions": {
            "billing": {
                "type": "noul",
                "instructions": "Is this message about billing?",
            }
        },
    }
elif mode == "ask":
    raw = sys.stdin.read()
    if not raw.strip():
        sys.stderr.write("Pass a System One JSON body on stdin, or run: harness/jev.sh test\n")
        sys.exit(2)
    body = json.loads(raw)
    body.setdefault("model", model)
else:
    sys.stderr.write("usage: harness/jev.sh test | harness/jev.sh < request.json\n")
    sys.exit(2)

req = urllib.request.Request(
    url,
    data=json.dumps(body).encode(),
    headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        payload = json.load(resp)
except urllib.error.HTTPError as err:
    detail = err.read().decode("utf-8", "replace").replace(key, "[redacted]")
    sys.stderr.write(f"Jev HTTP {err.code}: {detail}\n")
    sys.exit(1)
except urllib.error.URLError as err:
    sys.stderr.write(f"Jev request failed: {err.reason}\n")
    sys.exit(1)

if mode == "test":
    answer = payload.get("answers", {}).get("billing", {})
    noul = answer.get("noul")
    if not isinstance(noul, (int, float)):
        sys.stderr.write("Jev test response had no billing noul.\n")
        sys.exit(1)
    print(f"ok model={payload.get('model', '?')} billing_noul={noul}")
else:
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")
PY
