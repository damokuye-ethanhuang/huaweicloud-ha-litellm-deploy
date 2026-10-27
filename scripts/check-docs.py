#!/usr/bin/env python3
"""Keep the docs honest.

Two failure modes this catches, both of which have already happened in this repo:

  1. a rename in code leaves prose pointing at something that no longer exists
     (`elb_public_ip`, `config/litellm-config.yaml`, `make sync-config`, ...);
  2. a relative link points at a file or heading that was moved or deleted;
  3. a SKILL.md drifts out of the Agent Skills spec or past the 60-character
     description that the Hermes skills index shows (a skill that is one
     character over still looks fine in a browser, then loads truncated).

Banned tokens are deliberate: every one of them was a real stale reference. Add
a token here when you remove a concept, so it cannot come back.
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Agent Skills spec (https://agentskills.io/specification) plus this repo's
# description shape: the first sentence carries the trigger inside 60 chars —
# that is all a truncated index shows — and the whole field stays under 260.
SKILL_NAME_MAX = 64
SKILL_DESC_SPEC_MAX = 1024
SKILL_DESC_HEAD_MAX = 60
SKILL_DESC_TOTAL_MAX = 260
SKILL_BODY_LINE_WARN = 500
SKILL_NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
FRONTMATTER_RE = re.compile(r"\A---\r?\n(.*?)\r?\n---\r?\n", re.DOTALL)
FIRST_SENTENCE_RE = re.compile(r"^(.+?\.)(?:\s|$)")

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


def check_skills(errors: list[str]) -> int:
    """Validate every SKILL.md against the Agent Skills spec and the Hermes cap.

    A skill that is one character over a limit still renders fine on GitHub, but
    the agent that loads it truncates the description or refuses the skill, and
    neither failure is visible anywhere. Hence the mechanical check.
    """
    skills = sorted(
        path
        for path in (ROOT / "skills").rglob("SKILL.md")
        if len(path.relative_to(ROOT).parts) <= 4
    )
    if not skills:
        errors.append("skills/: no SKILL.md found (expected skills/<name>/SKILL.md)")
        return 0

    for path in skills:
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding="utf-8", errors="replace")

        match = FRONTMATTER_RE.match(text)
        if not match:
            errors.append(f"{rel}: no YAML frontmatter (file must start with '---' on line 1)")
            continue
        try:
            meta = yaml.safe_load(match.group(1))
        except yaml.YAMLError as exc:
            detail = str(exc).replace("\n", " ")
            errors.append(f"{rel}: frontmatter is not valid YAML: {detail}")
            continue
        if not isinstance(meta, dict):
            errors.append(f"{rel}: frontmatter must be a mapping")
            continue

        name = meta.get("name")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{rel}: missing required field 'name'")
        else:
            name = name.strip()
            if len(name) > SKILL_NAME_MAX:
                errors.append(f"{rel}: name is {len(name)} chars (max {SKILL_NAME_MAX})")
            if not SKILL_NAME_RE.match(name):
                errors.append(f"{rel}: name {name!r} is not lowercase-hyphen")
            if name != path.parent.name:
                errors.append(
                    f"{rel}: name {name!r} must equal its directory {path.parent.name!r}"
                )

        description = meta.get("description")
        if not isinstance(description, str) or not description.strip():
            errors.append(f"{rel}: missing required field 'description'")
        else:
            description = description.strip()
            if len(description) > SKILL_DESC_SPEC_MAX:
                errors.append(
                    f"{rel}: description is {len(description)} chars "
                    f"(spec max {SKILL_DESC_SPEC_MAX})"
                )
            sentence = FIRST_SENTENCE_RE.match(description)
            if not sentence:
                errors.append(
                    f"{rel}: description must open with a complete sentence ending in '.'"
                )
            else:
                head = sentence.group(1)
                if len(head) > SKILL_DESC_HEAD_MAX:
                    errors.append(
                        f"{rel}: first sentence is {len(head)} chars, must fit "
                        f"{SKILL_DESC_HEAD_MAX} — a truncated index shows only that much"
                    )
                if not head.startswith("Use when"):
                    errors.append(
                        f"{rel}: first sentence should start with 'Use when <trigger>.'"
                    )
            if len(description) >= SKILL_DESC_TOTAL_MAX:
                errors.append(
                    f"{rel}: description is {len(description)} chars, must stay under "
                    f"{SKILL_DESC_TOTAL_MAX} (60 for the trigger sentence, the rest detail)"
                )

        body = text[match.end():]
        body_lines = body.count("\n") + (1 if body and not body.endswith("\n") else 0)
        if not body.strip():
            errors.append(f"{rel}: body is empty")
        elif body_lines > SKILL_BODY_LINE_WARN:
            errors.append(
                f"{rel}: body is {body_lines} lines (recommended max {SKILL_BODY_LINE_WARN}); "
                "move reference material into references/"
            )

    return len(skills)


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
    skill_count = check_skills(errors)

    for error in errors:
        print(f"[fail] {error}")
    if errors:
        return 1
    print(
        f"docs ok: {len(files)} files, {skill_count} skill(s), "
        "links resolve, no removed concepts"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
