#!/usr/bin/env bash
# harness/outline.sh — signatures of tracked source files, without bodies.
#
# The outline shows what exists. It does not show that the code works.
# scripts/verify.sh is the check for that.
#
# Skips gitignored paths and vendored, lock, and generated files.
# Python uses the ast module. JS/TS, Go, Rust, and shell use text patterns.
# Any other tracked file is listed by path only.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

python3 - <<'PY'
import ast, os, re, subprocess, sys

SKIP_DIRS = {
    ".git", ".factory", "node_modules", "vendor", "third_party", "venv", ".venv",
    "dist", "build", "coverage", "__pycache__", "target", ".next", "out",
}
LOCK_NAMES = {
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "go.sum",
    "poetry.lock", "gemfile.lock", "composer.lock", "packages.lock.json",
    "pipfile.lock", "uv.lock", "shrinkwrap.json",
}
GENERATED_SUFFIXES = (
    ".min.js", ".min.css", ".map", ".pb.go", "_pb2.py", ".generated.ts",
    ".generated.js",
)

def skipped(path):
    parts = path.split("/")
    if any(part in SKIP_DIRS for part in parts):
        return True
    base = parts[-1].lower()
    if base in LOCK_NAMES or base.endswith(".lock"):
        return True
    lower = path.lower()
    if any(lower.endswith(suffix) for suffix in GENERATED_SUFFIXES):
        return True
    if "generated" in base:
        return True
    return False

def ignored(path):
    result = subprocess.run(
        ["git", "check-ignore", "-q", "--", path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0

def tracked():
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
    )
    raw = result.stdout.decode("utf-8", "replace")
    return [item for item in raw.split("\0") if item]

def clip(text):
    if not text:
        return ""
    line = text.strip().splitlines()[0].strip()
    if len(line) > 200:
        line = line[:200].rstrip() + "…"
    return line

def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""

def py_outline(path, source):
    lines = [path]
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return path

    def walk(nodes, indent):
        for node in nodes:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                args = [arg.arg for arg in node.args.args]
                prefix = "async def" if isinstance(node, ast.AsyncFunctionDef) else "def"
                lines.append(f"{indent}{prefix} {node.name}({', '.join(args)})")
                doc = clip(ast.get_docstring(node) or "")
                if doc:
                    lines.append(f"{indent}  {doc}")
            elif isinstance(node, ast.ClassDef):
                lines.append(f"{indent}class {node.name}")
                doc = clip(ast.get_docstring(node) or "")
                if doc:
                    lines.append(f"{indent}  {doc}")
                walk(node.body, indent + "  ")

    walk(tree.body, "  ")
    return "\n".join(lines)

def comment_above(rows, index):
    collected = []
    cursor = index - 1
    while cursor >= 0 and rows[cursor].strip() == "":
        cursor -= 1
    while cursor >= 0:
        text = rows[cursor].strip()
        if text.startswith("///") or text.startswith("//") or text.startswith("#"):
            collected.append(text.lstrip("/").lstrip("#").strip())
            cursor -= 1
            continue
        if text.endswith("*/"):
            block = []
            while cursor >= 0:
                block.append(rows[cursor].strip())
                if "/*" in rows[cursor]:
                    break
                cursor -= 1
            cleaned = []
            for piece in reversed(block):
                piece = piece.strip().lstrip("/*").rstrip("*/").lstrip("*").strip()
                if piece:
                    cleaned.append(piece)
            return clip(" ".join(cleaned))
        break
    if not collected:
        return ""
    collected.reverse()
    return clip(" ".join(collected))

def line_outline(path, source, patterns):
    rows = source.splitlines()
    found = [path]
    compiled = [(kind, re.compile(pattern)) for kind, pattern in patterns]
    for index, row in enumerate(rows):
        stripped = row.strip()
        if not stripped or stripped.startswith(("//", "#", "/*", "*", "///")):
            continue
        for kind, pattern in compiled:
            match = pattern.match(stripped)
            if not match:
                continue
            name = match.group(1)
            if name in {"if", "for", "while", "switch", "catch", "function", "class"}:
                continue
            found.append(f"  {kind} {name}")
            doc = comment_above(rows, index)
            if doc:
                found.append(f"    {doc}")
            break
    return "\n".join(found)

JS_PATTERNS = [
    ("function", r"^(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)"),
    ("class", r"^(?:export\s+)?(?:default\s+)?class\s+([A-Za-z_$][\w$]*)"),
    ("function", r"^(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|\()"),
    ("method", r"^(?:(?:public|private|protected|static|async|readonly|get|set)\s+)*([A-Za-z_$][\w$]*)\s*(?:<[^>]+>)?\([^;]*\)\s*(?::\s*[^{]+)?\{?$"),
]
GO_PATTERNS = [
    ("func", r"^func\s+(?:\([^)]*\)\s*)?([A-Za-z_][\w]*)\s*\("),
    ("type", r"^type\s+([A-Za-z_][\w]*)\s+(?:struct|interface)\b"),
]
RUST_PATTERNS = [
    ("fn", r"^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+([A-Za-z_][\w]*)"),
    ("type", r"^(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|type)\s+([A-Za-z_][\w]*)"),
    ("impl", r"^impl(?:<[^>]+>)?\s+([A-Za-z_][\w:]*)"),
]
SHELL_PATTERNS = [
    ("fn", r"^(?:function\s+)?([A-Za-z_][\w]*)\s*(?:\(\))?\s*\{"),
]

BY_EXT = {
    ".js": JS_PATTERNS, ".jsx": JS_PATTERNS, ".mjs": JS_PATTERNS, ".cjs": JS_PATTERNS,
    ".ts": JS_PATTERNS, ".tsx": JS_PATTERNS,
    ".go": GO_PATTERNS,
    ".rs": RUST_PATTERNS,
    ".sh": SHELL_PATTERNS, ".bash": SHELL_PATTERNS,
}

blocks = []
for path in tracked():
    if skipped(path) or ignored(path):
        continue
    ext = os.path.splitext(path)[1].lower()
    if ext == ".py":
        blocks.append(py_outline(path, read_text(path)))
    elif ext in BY_EXT:
        blocks.append(line_outline(path, read_text(path), BY_EXT[ext]))
    else:
        blocks.append(path)

sys.stdout.write("\n\n".join(blocks))
if blocks:
    sys.stdout.write("\n")
PY
