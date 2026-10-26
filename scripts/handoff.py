#!/usr/bin/env python3
"""Customer-data lifecycle for a deployment.

A customer hands over three things: AK/SK, the addresses that may SSH in, and
the model endpoints/keys. They land in two files, never in a chat or a commit:

  $LITELLM_DEPLOY_HOME/secrets/hw.env    AK/SK         (./scripts/creds.sh set)
  $LITELLM_DEPLOY_HOME/secrets/app.env   model API keys
  deploy-inputs.yaml  everything else, no secrets

This script is the round trip around that:

  form     print the block to send a customer - it says exactly where each value goes
  status   what is currently filled in, with secrets masked
  check    exit 1 if anything customer-specific is still present (run after a test)
  scrub    back up, then restore the placeholders; `check` must pass afterwards

Exit codes: 0 clean, 1 still dirty, 2 usage/parse problem.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent


def _runtime_home() -> Path:
    """Runtime state lives outside the repository; see scripts/lib.sh."""
    env = os.environ.get("LITELLM_DEPLOY_HOME")
    return Path(env).expanduser() if env else Path.home() / ".litellm-deploy"


RUNTIME_HOME = _runtime_home()
INPUTS = REPO / "deploy-inputs.yaml"
SECRETS = Path(os.environ.get("SECRETS_DIR") or RUNTIME_HOME / "secrets")
HW_ENV = SECRETS / "hw.env"
APP_ENV = SECRETS / "app.env"
BACKUPS = Path(os.environ.get("STATE_DIR") or RUNTIME_HOME / "state")

# Values that are obviously not a real customer: RFC 5737 documentation ranges
# and the <angle-bracket> placeholders used throughout the docs.
PLACEHOLDER_HOSTS = ("<", "example.invalid", "127.0.0.1", "localhost")
DOC_CIDRS = ("203.0.113.", "198.51.100.", "192.0.2.")

CUSTOMER_KEYS = {
    "project_name": "example-litellm",
    "owner": "",
    "client_cidrs": ["10.0.3.0/24"],
    "admin_cidrs": ["10.0.3.0/24"],
    "bastion_ssh_cidrs": ["203.0.113.10/32"],
}
MODEL_BASE_PLACEHOLDER = "https://<model-endpoint>/v1/"


def load_inputs() -> tuple[dict, dict[str, dict]]:
    doc = yaml.safe_load(INPUTS.read_text(encoding="utf-8")) or {}
    flat: dict[str, dict] = {}
    for section in doc.values():
        if isinstance(section, list):
            for item in section:
                if isinstance(item, dict) and "key" in item:
                    flat[item["key"]] = item
    return doc, flat


def env_values(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def mask(value: str) -> str:
    if not value:
        return "(empty)"
    if len(value) <= 8:
        return "****"
    return f"{value[:4]}...{value[-4:]}"


def is_placeholder_host(value: str) -> bool:
    return any(token in value for token in PLACEHOLDER_HOSTS)


def dirty_items() -> list[str]:
    problems: list[str] = []

    ak = HW_ENV.is_file() and bool(env_values(HW_ENV).get("HW_ACCESS_KEY"))
    if ak:
        problems.append(f"AK/SK still in {HW_ENV} (./scripts/creds.sh clear)")

    keys = env_values(APP_ENV)
    live = [k for k, v in keys.items() if v and not is_placeholder_host(v)]
    if live:
        problems.append(f"model keys still in {APP_ENV}: {', '.join(sorted(live))}")

    _, flat = load_inputs()
    cidrs = flat.get("bastion_ssh_cidrs", {}).get("value") or []
    public = [c for c in cidrs if not any(str(c).startswith(p) for p in DOC_CIDRS)]
    if public:
        problems.append(f"bastion_ssh_cidrs still holds customer addresses: {', '.join(map(str, public))}")

    for model in load_inputs()[0].get("models") or []:
        base = str(model.get("api_base") or "")
        if base and not is_placeholder_host(base):
            problems.append(f"model {model.get('name')} still points at {base}")
    return problems


def cmd_status() -> int:
    _, flat = load_inputs()
    keys = env_values(APP_ENV)

    print("customer data\n")
    print(f"  project_name        {flat.get('project_name', {}).get('value')}")
    print(f"  owner               {flat.get('owner', {}).get('value') or '(empty)'}")
    print(f"  bastion_ssh_cidrs   {', '.join(map(str, flat.get('bastion_ssh_cidrs', {}).get('value') or [])) or '(empty)'}")
    print(f"  client_cidrs        {', '.join(map(str, flat.get('client_cidrs', {}).get('value') or [])) or '(empty)'}")
    print(f"  admin_cidrs         {', '.join(map(str, flat.get('admin_cidrs', {}).get('value') or [])) or '(empty)'}")
    print(f"  AK                  {mask(env_values(HW_ENV).get('HW_ACCESS_KEY', '')) if HW_ENV.is_file() else f'(no {HW_ENV})'}")
    print(f"  model key vars      {', '.join(sorted(keys)) or f'(none in {APP_ENV})'}")
    print("\n  models:")
    for model in load_inputs()[0].get("models") or []:
        print(f"    {model.get('name'):<20} {model.get('api_base') or '(default endpoint)'}")
    return 0


def cmd_check() -> int:
    problems = dirty_items()
    if problems:
        print("customer data still present:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print("\nrun: ./scripts/handoff.py scrub", file=sys.stderr)
        return 1
    print("clean: no credentials, no customer addresses, no customer model endpoints")
    return 0


def replace_key_block(text: str, key: str, new_value: str) -> tuple[str, bool]:
    """Rewrite the `value:` line of `- key: <key>` without touching comments."""
    pattern = re.compile(
        rf"(?ms)^(\s*-\s*key:\s*{re.escape(key)}\s*\n(?:[ \t].*\n|\s*\n)*?[ \t]*value:)[^\n]*"
    )
    new_text, count = pattern.subn(rf"\1 {new_value}", text, count=1)
    return new_text, count == 1


def cmd_scrub() -> int:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = BACKUPS / f"handoff-{stamp}"
    backup.mkdir(parents=True, exist_ok=True)
    shutil.copy2(INPUTS, backup / INPUTS.name)
    for path in (HW_ENV, APP_ENV):
        if path.is_file():
            shutil.copy2(path, backup / path.name)

    text = INPUTS.read_text(encoding="utf-8")
    for key, value in CUSTOMER_KEYS.items():
        rendered = json.dumps(value) if isinstance(value, list) else json.dumps(str(value))
        text, ok = replace_key_block(text, key, rendered)
        if not ok:
            print(f"warning: could not rewrite {key}; edit it by hand", file=sys.stderr)

    # Model endpoints: keep the model ids, drop the customer's addresses.
    text = re.sub(r"(?m)^(\s*api_base:\s*).*$", rf"\1{MODEL_BASE_PLACEHOLDER}", text)
    INPUTS.write_text(text, encoding="utf-8")

    HW_ENV.unlink(missing_ok=True)
    APP_ENV.unlink(missing_ok=True)

    print(f"backup:  {backup}")
    print(f"cleared: {HW_ENV}, {APP_ENV}, customer fields in deploy-inputs.yaml")
    print("verify:  ./scripts/handoff.py check")
    return 0


def cmd_form() -> int:
    print(
        """\
Send this to the customer. Nothing here is a secret yet; they fill it in.

1) AK/SK  - never in chat, never in git
   Run ./scripts/creds.sh set (hidden input) - it writes
   $LITELLM_DEPLOY_HOME/secrets/hw.env, outside this repository:

     HW_ACCESS_KEY=<access key id>
     HW_SECRET_KEY=<secret access key>
     HW_PROJECT_ID=<project id, optional>

   Ask for a dedicated IAM user, not the account owner. Permissions: VPC, ECS,
   CCE, ELB, RDS, DCS, NAT, VPCEP, KMS/CSMS, LTS/AOM, SWR pull.

2) Who may SSH to the bastion  (public IPs are accepted ONLY here)
   deploy-inputs.yaml -> access.bastion_ssh_cidrs
     bastion_ssh_cidrs: ["<office-egress-ip>/32", "<second-ip>/32"]

3) Who may call the gateway  (VPC-internal ranges only; the ELB has no EIP)
   deploy-inputs.yaml -> access.client_cidrs / access.admin_cidrs

4) Backend models - one line each, the key goes in secrets/app.env
   name | api_base | api_key_env | model

   example:
     glm-5.3               | https://<vpce-ip>/v2/  | GLM_API_KEY      | openai/glm-5.3
     deepseek-v4.1-flash   | https://<vpce-ip>/v1/  | DEEPSEEK_API_KEY | openai/deepseek-v4.1-flash

   api_key_env is a variable NAME; the value goes in secrets/app.env:

     GLM_API_KEY=<key>
     DEEPSEEK_API_KEY=<key>      # leave the var out entirely if the endpoint is unauthenticated

5) Project name - prefix for every resource, 3-24 chars, lowercase
   deploy-inputs.yaml -> project_name

After the test: ./scripts/handoff.py scrub && ./scripts/handoff.py check
"""
    )
    return 0


def cmd_models(lines: list[str]) -> int:
    """Apply `name | api_base | api_key | model` rows to deploy-inputs.yaml."""
    text = INPUTS.read_text(encoding="utf-8")
    base_line = re.search(r"(?m)^models:\s*$", text)
    if not base_line:
        print("error: deploy-inputs.yaml has no top-level `models:` block", file=sys.stderr)
        return 2

    entries = []
    key_vars: list[str] = []
    for raw in lines:
        for chunk in raw.splitlines():
            chunk = chunk.strip()
            if not chunk or chunk.startswith("#"):
                continue
            parts = [p.strip() for p in chunk.split("|")]
            if len(parts) < 4:
                print(f"error: need 4 fields 'name | api_base | api_key | model', got: {chunk}", file=sys.stderr)
                return 2
            name, api_base, api_key, model = parts[0], parts[1], parts[2], parts[3]
            # glm-5.3 -> GLM_API_KEY, deepseek-v4.1-flash -> DEEPSEEK_API_KEY:
            # take the leading name segment and drop the version numbers, so a
            # version bump (v4.2) does not orphan the key variable.
            head = name.split(".")[0]
            head = re.sub(r"[-_]?v?\d+$", "", head)
            env = re.sub(r"[^A-Z0-9]+", "_", head.upper()).strip("_") + "_API_KEY"
            key_vars.append(f"{env}={api_key}" if api_key else f"# {env}=")
            entries.append(
                {
                    "name": name,
                    "model": model,
                    "api_base": api_base,
                    "api_key_env": env,
                    "api_key": "",
                    "mode": "chat",
                    "max_tokens": 8192,
                    "rpm": None,
                    "tpm": None,
                }
            )

    if not entries:
        print("error: no model rows given", file=sys.stderr)
        return 2

    rendered = yaml.safe_dump({"models": entries}, sort_keys=False, default_flow_style=False, allow_unicode=True)
    # Replace everything from `models:` to the next top-level key.
    pattern = re.compile(r"(?ms)^models:\s*$.*?(?=^\S|\Z)")
    new_text, count = pattern.subn(rendered + "\n", text, count=1)
    if count != 1:
        print("error: could not locate the models block", file=sys.stderr)
        return 2
    INPUTS.write_text(new_text, encoding="utf-8")

    print(f"wrote {len(entries)} model(s) to {INPUTS.relative_to(REPO)}:")
    for entry in entries:
        print(f"  {entry['name']:<22} {entry['api_base']:<40} {entry['model']}")
    print("\nkeys belong in secrets/app.env, one per api_key_env:")
    for line in key_vars:
        print(f"  {line}")
    print("\nthen: ./scripts/deploy.sh preflight")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["form", "status", "check", "scrub", "models"])
    ap.add_argument("rows", nargs="*", help="models: one 'name | api_base | api_key | model' per argument")
    args = ap.parse_args()
    if args.action == "models":
        return cmd_models(args.rows)
    return {"form": cmd_form, "status": cmd_status, "check": cmd_check, "scrub": cmd_scrub}[args.action]()


if __name__ == "__main__":
    sys.exit(main())
