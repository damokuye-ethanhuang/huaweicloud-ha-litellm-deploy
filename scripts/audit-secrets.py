#!/usr/bin/env python3
"""Pre-publication audit: credentials, customer identifiers, PII.

Three layers, because each one misses what the others catch:

  1. forbidden paths - a saved plan, a state file, a private key, a kubeconfig
     or secrets/*.env is a finding by name alone. `tfplan2` was committed once
     with the generated database password inside; it is a zip archive, so no
     content grep would ever have seen it. Never rely on content here.
  2. content patterns - AK/SK, `sk-` keys, private-key blocks, JWT, password
     assignments, public IPv4 outside the documentation ranges, account names,
     instance ids.
  3. git history - every blob ever committed, including files deleted since.
     A secret removed by `git rm` is still in the object database and still
     published by `git push`.

Matches are printed masked, so this is safe to paste into an issue. Exit code
is 1 when anything requires action, which is what CI and `make audit` use.

Usage:
    ./scripts/audit-secrets.py              # paths + content + history
    ./scripts/audit-secrets.py --no-history # fast, pre-commit use
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# --- layer 1: names that are never safe to publish -------------------------

FORBIDDEN = re.compile(
    r"(^|/)("
    r"tfplan[^/]*|.*\.tfplan|.*\.tfplan\.json|"
    r".*\.tfstate|.*\.tfstate\..*|"
    r".*\.pem|.*\.key|.*\.p12|.*\.pfx|.*\.jks|"
    r"kubeconfig.*|.*\.kubeconfig|"
    r"\.env|\.env\..*|secrets/.*\.env|"
    r"id_rsa.*|id_ed25519.*|bastion_key"
    r")$"
)

# Expected, documented exceptions.
FORBIDDEN_ALLOW = {
    ".env.example",
    "secrets/app.env.example",
    "secrets/hw.env.example",
    "secrets/README.md",
    "charts/litellm/secrets.example.yaml",
}

# --- layer 2: content ------------------------------------------------------

SECRET_PATTERNS = [
    ("huawei-ak", r"\bAK\s*[:=]\s*[A-Z0-9]{16,}", "secret"),
    ("huawei-sk", r"\bSK\s*[:=]\s*[A-Za-z0-9/+]{30,}", "secret"),
    ("huawei-ak-env", r"HW_ACCESS_KEY\s*=\s*[A-Z0-9]{16,}", "secret"),
    ("huawei-sk-env", r"HW_SECRET_KEY\s*=\s*[A-Za-z0-9/+]{30,}", "secret"),
    ("api-key", r"\bsk-[A-Za-z0-9][A-Za-z0-9_\-]{10,}", "secret"),
    ("master-key", r"(?i)\bmaster[_-]?key\s*[:=]\s*\S{10,}", "secret"),
    ("salt-key", r"(?i)\bsalt[_-]?key\s*[:=]\s*\S{10,}", "secret"),
    ("private-key", r"-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----", "secret"),
    ("password", r"(?i)\b(?:password|passwd|pwd)\s*[:=]\s*['\"]?[^\s'\"$<{]{6,}", "secret"),
    ("jwt", r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.", "secret"),
    ("public-ipv4", r"\b(?:(?:[1-9]\d?|1\d\d|2[0-4]\d|25[0-5])\.){3}(?:[1-9]\d?|1\d\d|2[0-4]\d|25[0-5])\b", "pii"),
    ("email", r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b", "pii"),
    ("huawei-account", r"\bhwstaff[_\-]?[A-Za-z0-9]+\b", "pii"),
    ("instance-id", r"\b[0-9a-f]{32}in\d{2}\b", "pii"),
    ("uuid", r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", "pii"),
]

SECRET_PATTERNS = [(name, re.compile(regex), severity) for name, regex, severity in SECRET_PATTERNS]

NOT_A_VALUE = re.compile(
    r"(?i)(\$\{|\$[A-Z_]|<|random_password|var\.|local\.|module\.|data\.|"
    r"huaweicloud_|os\.environ|getenv|example|placeholder|your[-_]|\*\*\*|xxx|"
    r"\.result|\.name|required|optional)"
)

IP_ALLOW = (
    "127.", "0.0.0.0", "255.255.255.255", "169.254.", "224.", "240.",
    "10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.2", "172.30.", "172.31.",
    "192.168.", "100.64.", "100.125.", "203.0.113.", "198.51.100.", "192.0.2.", "198.18.",
)

TEXT_SUFFIX = {
    ".md", ".yaml", ".yml", ".json", ".tf", ".tfvars", ".py", ".sh", ".tpl", ".txt",
    ".html", ".css", ".js", ".svg", ".drawio", ".example", ".conf", ".ini", ".toml",
    ".xml", ".j2", ".gotmpl",
}
TEXT_NAMES = {".gitignore", ".dockerignore", "Makefile", "Dockerfile", "LICENSE", "NOTICE"}


def mask(value: str) -> str:
    return f"{value[:3]}***{value[-2:]}(len={len(value)})" if len(value) > 8 else "***"


def iter_matches(text: str):
    for name, regex, severity in SECRET_PATTERNS:
        for m in regex.finditer(text):
            value = m.group(0)
            if name == "public-ipv4" and (value.startswith(IP_ALLOW) or value.endswith((".0", ".255"))):
                continue
            rhs = value.split("=", 1)[-1].split(":", 1)[-1].strip() if name in (
                "password", "master-key", "salt-key", "huawei-ak", "huawei-sk", "huawei-ak-env", "huawei-sk-env"
            ) else ""
            if rhs and NOT_A_VALUE.search(rhs):
                continue
            if name == "uuid" and value.startswith("00000000"):
                continue
            # Documented placeholders: an API key that is literally "not required"
            # and RFC 2606 example domains.
            if name == "api-key" and re.match(r"^sk-(not-)?(required|configured|needed|set|placeholder|xxx)", value):
                continue
            if name == "email" and value.endswith(("@example.com", "@example.invalid", "@example.org")):
                continue
            line_no = text.count("\n", 0, m.start()) + 1
            line = text.splitlines()[line_no - 1].strip() if text.splitlines() else ""
            yield name, severity, value, line_no, line.replace(value, mask(value))[:140]


def is_text(path: str) -> bool:
    p = Path(path)
    return p.suffix.lower() in TEXT_SUFFIX or p.name in TEXT_NAMES


def read_text(path: Path) -> str | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if b"\x00" in data[:4000]:
        return None
    return data.decode("utf-8", errors="replace")


# --- scan layers -----------------------------------------------------------


def tracked_files() -> list[str]:
    out = subprocess.run(["git", "-C", str(REPO), "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p.decode() for p in out.split(b"\x00") if p]


def scan_tree(files: list[str]) -> dict:
    forbidden, findings = [], []
    for rel in files:
        if FORBIDDEN.search(rel) and rel not in FORBIDDEN_ALLOW:
            forbidden.append(rel)
            continue  # a forbidden path is reported once, not byte-scanned
        if not is_text(rel):
            continue
        text = read_text(REPO / rel)
        if text is None:
            continue
        for name, severity, value, line_no, line in iter_matches(text):
            findings.append({"path": rel, "line": line_no, "rule": name, "severity": severity, "snippet": line})
    return {"forbidden": forbidden, "content": findings}


def history_paths() -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(REPO), "log", "--all", "--pretty=format:", "--name-only"],
        capture_output=True, check=True, text=True,
    ).stdout
    return sorted({line.strip() for line in out.splitlines() if line.strip()})


def history_blobs() -> list[tuple[str, str]]:
    """(sha, path) for every blob reachable from any ref, deleted ones included."""
    out = subprocess.run(
        ["git", "-C", str(REPO), "rev-list", "--objects", "--all"], capture_output=True, check=True, text=True
    ).stdout
    pairs = []
    for line in out.splitlines():
        parts = line.split(" ", 1)
        if len(parts) == 2:
            pairs.append((parts[0], parts[1]))
    return pairs


def scan_history() -> dict:
    forbidden = [p for p in history_paths() if FORBIDDEN.search(p) and p not in FORBIDDEN_ALLOW]

    pairs = history_blobs()
    if not pairs:
        return {"forbidden": forbidden, "content": [], "blobs": 0}
    check = subprocess.run(
        ["git", "-C", str(REPO), "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
        input="\n".join(sha for sha, _ in pairs).encode(), capture_output=True, check=True,
    ).stdout.decode().splitlines()
    sizes = {}
    for row in check:
        parts = row.split()
        if len(parts) == 3 and parts[1] == "blob":
            sizes[parts[0]] = int(parts[2])

    wanted = [(sha, path) for sha, path in pairs if sha in sizes and sizes[sha] <= 2_000_000 and is_text(path)]
    findings = []
    if not wanted:
        return {"forbidden": forbidden, "content": [], "blobs": len(sizes)}

    batch = subprocess.Popen(
        ["git", "-C", str(REPO), "cat-file", "--batch"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    )
    assert batch.stdin and batch.stdout
    try:
        for sha, path in wanted:
            batch.stdin.write(f"{sha}\n".encode())
            batch.stdin.flush()
            header = batch.stdout.readline().split()
            if len(header) < 3 or header[1] != b"blob":
                continue
            data = batch.stdout.read(int(header[2]))
            batch.stdout.read(1)  # trailing newline after each object
            if b"\x00" in data[:4000]:
                continue
            text = data.decode("utf-8", errors="replace")
            for name, severity, _value, line_no, line in iter_matches(text):
                findings.append(
                    {"path": f"{path} @{sha[:8]}", "line": line_no, "rule": name, "severity": severity, "snippet": line}
                )
    finally:
        batch.stdin.close()
        batch.wait()
    return {"forbidden": forbidden, "content": findings, "blobs": len(sizes)}


def local_only() -> list[str]:
    """Sensitive files present but ignored - must not be archived with the repo."""
    out = subprocess.run(
        ["git", "-C", str(REPO), "status", "--ignored", "--porcelain", "-z"],
        capture_output=True, check=True,
    ).stdout.split(b"\x00")
    hits = []
    for entry in out:
        if not entry.startswith(b"!! "):
            continue
        rel = entry[3:].decode(errors="replace")
        if FORBIDDEN.search(rel) or rel.rstrip("/") in ("out", ".local", ".venv-sdk"):
            hits.append(rel.rstrip("/"))
    return sorted(set(hits))


def main() -> int:
    ap = argparse.ArgumentParser(description="Pre-publication secret and PII audit.")
    ap.add_argument("--no-history", action="store_true", help="skip the git-history scan")
    args = ap.parse_args()

    files = tracked_files()
    tree = scan_tree(files)
    hist = {"forbidden": [], "content": [], "blobs": 0} if args.no_history else scan_history()

    print(f"tracked files: {len(files)}" + ("" if args.no_history else f", history blobs: {hist['blobs']}"))

    blocking = 0
    if tree["forbidden"]:
        print(f"\nforbidden path in the tree ({len(tree['forbidden'])})")
        for path in tree["forbidden"]:
            print(f"  {path}")
        blocking += len(tree["forbidden"])

    if hist["forbidden"]:
        print(f"\nforbidden path in history ({len(hist['forbidden'])})")
        for path in hist["forbidden"]:
            print(f"  {path}")
        blocking += len(hist["forbidden"])

    for label, rows in (("tree", tree["content"]), ("history", hist["content"])):
        secrets = [r for r in rows if r["severity"] == "secret"]
        pii = [r for r in rows if r["severity"] == "pii"]
        if secrets:
            print(f"\nsecret patterns in {label} ({len(secrets)})")
            for r in secrets:
                print(f"  {r['path']}:{r['line']}  [{r['rule']}]  {r['snippet']}")
            blocking += len(secrets)
        if pii:
            print(f"\nidentifier/PII patterns in {label} ({len(pii)})")
            seen = set()
            for r in pii:
                key = (r["path"], r["rule"])
                if key in seen:
                    continue
                seen.add(key)
                print(f"  {r['path']}:{r['line']}  [{r['rule']}]  {r['snippet']}")

    runtime = Path(os.environ.get("LITELLM_DEPLOY_HOME") or Path.home() / ".litellm-deploy")
    if runtime.is_dir():
        print(f"\nruntime dir (expected, outside the repository): {runtime}")

    ignored = local_only()
    if ignored:
        print(f"\nlocal-only sensitive files ({len(ignored)}) - ignored by git, do not archive")
        for path in ignored:
            print(f"  {path}")

    if blocking:
        print(f"\nFAIL: {blocking} blocking finding(s). Nothing here may be pushed.")
        return 1
    print("\nclean: no credentials, customer identifiers or PII in the tree or its history")
    return 0


if __name__ == "__main__":
    sys.exit(main())
