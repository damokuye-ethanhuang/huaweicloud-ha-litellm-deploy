#!/usr/bin/env python3
"""Keep the docs honest.

Two failure modes this catches, both of which have already happened in this repo:

  1. a rename in code leaves prose pointing at something that no longer exists
     (`elb_public_ip`, `config/litellm-config.yaml`, `make sync-config`, ...);
  2. a relative link points at a file or heading that was moved or deleted.

Banned tokens are deliberate: every one of them was a real stale reference. Add
a token here when you remove a concept, so it cannot come back.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Removed or renamed concepts. Prose must not mention them.
BANNED = {
    "elb_public_ip": "use gateway_private_ip (the ELB is internal)",
    "elb_ingress_cidrs": "use client_cidrs / admin_cidrs",
    "ssh_ingress_cidrs": "use bastion_ssh_cidrs",
    "MODELARTS_API_BASE": "declare api_base per model in deploy-inputs.yaml",
    "MODELARTS_API_KEY": "use api_key_env + secrets/app.env",
    "config/litellm-config.yaml": "the chart renders config from values + inputs",
    "make sync-config": "removed; preflight renders the config",
    "make plan": "use ./scripts/deploy.sh plan",
    "make apply": "use ./scripts/deploy.sh apply-infra",
    "scripts/preflight.sh": "use ./scripts/deploy.sh preflight",
    "scripts/deploy-infra.sh": "use ./scripts/deploy.sh",
    "scripts/bastion-exec.sh": "use ./scripts/remote-deploy.sh exec",
    "maas-container-subnet": "container networking is overlay_l2 (VXLAN); the pod CIDR is not a VPC subnet",
}

# Files allowed to mention removed concepts (history, this checker).
EXEMPT = {
    "CHANGELOG.md",
    "scripts/check-docs.py",
}

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


SKIP_DIRS = {".git", ".terraform", "out", "dist", "node_modules", ".venv", ".venv-sdk"}


def tracked_markdown() -> list[pathlib.Path]:
    files = []
    for path in ROOT.rglob("*.md"):
        parts = path.relative_to(ROOT).parts
        # Skip tool caches (provider READMEs under .terraform/) and build output;
        # only this repository's own prose is in scope.
        if any(part in SKIP_DIRS or part.startswith(".") for part in parts[:-1]):
            continue
        files.append(path)
    return sorted(files)


def heading_anchors(path: pathlib.Path) -> set[str]:
    anchors: set[str] = set()
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r"^#{1,4}\s+(.*)$", line)
        if not match:
            continue
        text = match.group(1).strip().lower()
        text = re.sub(r"[`*_]", "", text)
        text = re.sub(r"[^\w\s-]", "", text)
        anchors.add(re.sub(r"\s+", "-", text))
    return anchors


def check_links(path: pathlib.Path, errors: list[str]) -> list[str]:
    """Resolve every relative link; return the link targets (for README parity)."""
    targets: list[str] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    for raw in LINK_RE.findall(text):
        target = raw.strip()
        if target.startswith(("http://", "https://", "mailto:", "#")):
            if target.startswith("#"):
                anchor = target[1:]
                if anchor and anchor not in heading_anchors(path):
                    rel = path.relative_to(ROOT).as_posix()
                    errors.append(f"{rel}: anchor #{anchor} not found in this file")
            continue
        targets.append(target)
        file_part, _, anchor = target.partition("#")
        resolved = (path.parent / file_part).resolve()
        rel = path.relative_to(ROOT).as_posix()
        if not resolved.exists():
            errors.append(f"{rel}: link target does not exist: {target}")
            continue
        if anchor and resolved.suffix == ".md" and anchor not in heading_anchors(resolved):
            errors.append(f"{rel}: link anchor not found: {target}")
    return targets


def check_banned(path: pathlib.Path, errors: list[str]) -> None:
    rel = path.relative_to(ROOT).as_posix()
    if rel in EXEMPT:
        return
    text = path.read_text(encoding="utf-8", errors="replace")
    for token, advice in BANNED.items():
        if token in text:
            errors.append(f"{rel}: mentions removed {token!r} — {advice}")


def check_inventory(errors: list[str]) -> None:
    """Every script, module and document must be described in docs/index.md.

    A file map is only useful while it is complete; without this check it rots
    one commit after it is written (which is how 20 probe scripts ended up
    undocumented at the repository root).
    """
    index = ROOT / "docs" / "index.md"
    if not index.exists():
        errors.append("docs/index.md is missing — it is the file map")
        return
    text = index.read_text(encoding="utf-8", errors="replace")

    required: list[pathlib.Path] = [p for p in (ROOT / "scripts").iterdir() if p.is_file()]
    required += [p for p in (ROOT / "terraform" / "modules").iterdir() if p.is_dir()]
    required += [p for p in (ROOT / "docs").glob("*.md") if p.name != "index.md"]

    for path in sorted(required):
        name = path.name if path.is_dir() else path.relative_to(ROOT).as_posix()
        if name not in text:
            kind = "module" if path.is_dir() else "file"
            errors.append(f"docs/index.md: {kind} {name} is not documented in the file map")


def main() -> int:
    errors: list[str] = []
    files = tracked_markdown()
    if not files:
        print("[fail] no markdown files found")
        return 1

    link_sets: dict[str, set[str]] = {}
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        targets = check_links(path, errors)
        check_banned(path, errors)
        if rel in ("README.md", "README.zh-CN.md"):
            link_sets[rel] = {t for t in targets if not t.startswith("#")}

    # The two READMEs must point at the same set of files, or one of them rots.
    if len(link_sets) == 2:
        # Language variants are expected to differ: README.md links the English
        # diagram, README.zh-CN.md the Chinese one. Everything else must match.
        def same_in_both(target: str) -> bool:
            return not any(marker in target for marker in (".zh-CN.", "-zh-CN.", "_zh-CN."))

        only_en = {t for t in link_sets["README.md"] - link_sets["README.zh-CN.md"] if same_in_both(t)}
        only_zh = {t for t in link_sets["README.zh-CN.md"] - link_sets["README.md"] if same_in_both(t)}
        for target in sorted(only_en):
            errors.append(f"README.zh-CN.md: missing link to {target} (present in README.md)")
        for target in sorted(only_zh):
            errors.append(f"README.md: missing link to {target} (present in README.zh-CN.md)")

    check_inventory(errors)

    for error in errors:
        print(f"[fail] {error}")
    if errors:
        return 1
    print(f"docs ok: {len(files)} files, links resolve, no removed concepts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
