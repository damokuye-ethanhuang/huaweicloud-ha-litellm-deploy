#!/usr/bin/env bash
# Offline validation: formatting, module validation, chart lint, script lint.
# Runs in CI without any cloud credentials.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail=0
step() { printf '\n=== %s ===\n' "$*"; }

step "terraform fmt"
terraform fmt -check -recursive terraform || fail=1

step "terraform validate"
for dir in terraform/modules/* terraform/examples/*; do
  [ -d "$dir" ] || continue
  printf '  %-40s' "$dir"
  if terraform -chdir="$dir" init -backend=false -input=false -no-color >/dev/null 2>&1 &&
    terraform -chdir="$dir" validate -no-color >/dev/null; then
    echo ok
  else
    echo FAILED
    terraform -chdir="$dir" validate -no-color || true
    fail=1
  fi
done

step "helm lint"
helm lint charts/litellm --set existingSecret=ci-secret || fail=1

step "helm template"
helm template litellm charts/litellm --namespace litellm --set existingSecret=ci-secret >/dev/null || fail=1

if command -v shellcheck >/dev/null 2>&1; then
  step "monitoring"
python3 ./scripts/check-monitoring.py || fail=1

step "shellcheck"
  shellcheck -x scripts/*.sh terraform/examples/vm-single/templates/start.sh || fail=1
else
  step "shellcheck (skipped: not installed)"
fi

if [ "$fail" -ne 0 ]; then
  printf '\nvalidation failed\n' >&2
  exit 1
fi

printf '\nall checks passed\n'
