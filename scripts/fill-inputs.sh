#!/usr/bin/env bash
# Fill the four values a human must decide, in deploy-inputs.yaml - nothing else.
#
#   ./scripts/fill-inputs.sh              ask, validate, write the file
#   ./scripts/fill-inputs.sh --show       print the four current values and exit
#   PROJECT_NAME=acme OWNER=team BASTION_SSH_CIDRS=1.2.3.4/32 SWR_ORG=acme \
#     ./scripts/fill-inputs.sh --yes      non-interactive (CI, or an agent driven by a prompt)
#
# Everything else in deploy-inputs.yaml already holds the values the first real
# deployment proved; this script exists so nobody has to guess which of the 55
# parameters are actually theirs to change.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FILE="$(repo_root)/deploy-inputs.yaml"
MODE="ask"
[ "${1:-}" = "--show" ] && MODE="show"
[ "${1:-}" = "--yes" ] && MODE="noninteractive"

read_current() {
  python3 - "$FILE" "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
for items in doc.values():
    if isinstance(items, list):
        for item in items:
            if isinstance(item, dict) and item.get("key") == sys.argv[2]:
                v = item.get("value")
                print(", ".join(map(str, v)) if isinstance(v, list) else ("" if v is None else v))
                sys.exit(0)
PY
}

if [ "$MODE" = "show" ]; then
  printf 'file: %s\n\n' "$FILE"
  printf '  project_name      %s\n' "$(read_current project_name)"
  printf '  owner             %s\n' "$(read_current owner)"
  printf '  bastion_ssh_cidrs %s\n' "$(read_current bastion_ssh_cidrs)"
  printf '  swr_org           %s\n' "$(read_current swr_org)"
  printf '\nfill them: ./scripts/fill-inputs.sh\n'
  exit 0
fi

current_project="$(read_current project_name)"
current_owner="$(read_current owner)"
current_bastion="$(read_current bastion_ssh_cidrs)"
current_swr="$(read_current swr_org)"

if [ "$MODE" = "noninteractive" ]; then
  project="${PROJECT_NAME:-}"; owner="${OWNER:-}"
  bastion="${BASTION_SSH_CIDRS:-}"; swr="${SWR_ORG:-$project}"
else
  [ -t 0 ] || die "stdin is not a terminal; use PROJECT_NAME=... ./scripts/fill-inputs.sh --yes"

  printf '\n只改一个文件：%s\n\n' "$FILE"
  printf '1/4 project_name  —— 所有资源名的前缀（VPC/CCE/RDS/ELB/SWR 组织都用它）\n'
  printf '     3-24 位，小写字母开头，只含小写字母、数字、连字符。两个项目不能同名。\n'
  printf '     current: %s\n  > ' "$current_project"
  IFS= read -r project

  printf '\n2/4 owner  —— 写进每个资源的 tag，账单和告警按它归属。\n'
  printf '     团队名或邮箱前缀，2-40 字符。留空 preflight 会直接 FAIL。\n'
  printf '     current: %s\n  > ' "${current_owner:-（空）}"
  IFS= read -r owner

  printf '\n3/4 bastion_ssh_cidrs  —— 允许 SSH 堡垒机的公网出口 IP，是全套架构唯一的公网入口。\n'
  printf '     多个出口用逗号分隔。查你自己的出口：curl -s ifconfig.me\n'
  printf '     填错的症状是 SSH 连接超时（不是拒绝），后面每个阶段都做不了。\n'
  printf '     current: %s\n  > ' "$current_bastion"
  IFS= read -r bastion

  printf '\n4/4 swr_org  —— 镜像推到哪个 SWR 组织，建议与 project_name 一致。\n'
  printf '     组织需先在 SWR 控制台存在；节点无出网，镜像只能走堡垒机→SWR→Pod。\n'
  printf '     current: %s (Enter = 用 project_name)\n  > ' "$current_swr"
  IFS= read -r swr
fi

project="${project:-$current_project}"
owner="${owner:-$current_owner}"
bastion="${bastion:-$current_bastion}"
swr="${swr:-$project}"

python3 - "$FILE" "$project" "$owner" "$bastion" "$swr" <<'PY'
import ipaddress
import re
import sys

path, project, owner, bastion_raw, swr = sys.argv[1:6]
errors = []

if not re.fullmatch(r"[a-z][a-z0-9-]{2,23}", project):
    errors.append("project_name: 3-24 chars, lowercase letter first, only a-z 0-9 -")
if not (2 <= len(owner) <= 40):
    errors.append("owner: 2-40 characters")
if not re.fullmatch(r"[a-z][a-z0-9-]{0,62}", swr):
    errors.append("swr_org: lowercase letter first, only a-z 0-9 -")

cidrs = [c.strip() for c in re.split(r"[,\s]+", bastion_raw) if c.strip()]
if not cidrs:
    errors.append("bastion_ssh_cidrs: at least one CIDR")
for c in cidrs:
    try:
        ipaddress.ip_network(c, strict=False)
    except ValueError:
        errors.append(f"bastion_ssh_cidrs: {c!r} is not a CIDR (expected e.g. 1.2.3.4/32)")

if errors:
    print("\n".join(f"  [fail] {e}" for e in errors), file=sys.stderr)
    sys.exit(2)

values = {
    "project_name": project,
    "owner": owner,
    "bastion_ssh_cidrs": "[" + ", ".join(f'"{c}"' for c in cidrs) + "]",
    "swr_org": swr,
}

lines = open(path, encoding="utf-8").read().splitlines()
changed = {}
for key, new_value in values.items():
    for i, line in enumerate(lines):
        if line.strip() == f"- key: {key}":
            for j in range(i + 1, min(i + 6, len(lines))):
                if lines[j].lstrip().startswith("value:"):
                    indent = len(lines[j]) - len(lines[j].lstrip())
                    old = lines[j].split("value:", 1)[1].strip()
                    if old.strip('"') != new_value.strip('"'):
                        lines[j] = " " * indent + f"value: {new_value}"
                        changed[key] = (old, new_value)
                    break
            break

open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
for key, (old, new) in changed.items():
    print(f"  {key}: {old}  ->  {new}")
if not changed:
    print("  nothing to change: the four values are already set")
PY

printf '\n下一步（不会创建任何资源）：\n'
printf '  ./scripts/deploy.sh preflight     # 期望：0 blocking\n'
printf '  ./scripts/deploy.sh plan          # 生成 plan，停下来等你确认\n'
