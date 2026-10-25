#!/usr/bin/env bash
# Check the local toolchain and print the versions the repository expects.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

check() {
  local tool="$1" hint="$2"
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  %-12s %s\n' "$tool" "$("$tool" version 2>/dev/null | head -1 || "$tool" --version 2>/dev/null | head -1)"
  else
    printf '  %-12s MISSING - %s\n' "$tool" "$hint"
  fi
}

printf 'required:\n'
check terraform "https://developer.hashicorp.com/terraform/install"
check helm "https://helm.sh/docs/intro/install/"
check kubectl "https://kubernetes.io/docs/tasks/tools/"
check jq "package manager"
check curl "package manager"

printf '\noptional:\n'
check docker "needed for scripts/mirror-image.sh"
check shellcheck "needed for scripts/lint.sh"
check tflint "extra Terraform linting"

printf '\ncredentials (never commit these):\n'
"$(dirname "$0")/creds.sh" status | sed 's/^/  /'
printf '\n  fill them with: ./scripts/creds.sh set   (writes secrets/hw.env, chmod 600)\n'
printf '  clear after testing: ./scripts/creds.sh clear\n'
