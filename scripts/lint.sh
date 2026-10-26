#!/usr/bin/env bash
# Offline validation: formatting, module validation, chart lint, script lint.
# Runs in CI without any cloud credentials.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail=0
TMP_LOG="$(mktemp)"
trap 'rm -f "$TMP_LOG"' EXIT
step() { printf '\n=== %s ===\n' "$*"; }

step "terraform fmt"
terraform fmt -check -recursive terraform || fail=1

step "terraform validate"
for dir in terraform/modules/* terraform/examples/*; do
  [ -d "$dir" ] || continue
  printf '  %-40s' "$dir"
  # Keep the output: a swallowed init/validate error used to leave only
  # "FAILED" behind, which is worse than useless when it is a syntax error.
  if terraform -chdir="$dir" init -backend=false -input=false -no-color >"$TMP_LOG" 2>&1 &&
    terraform -chdir="$dir" validate -no-color >"$TMP_LOG" 2>&1; then
    echo ok
  else
    echo FAILED
    grep -E '^(Error|│ *Error)|on .* line' "$TMP_LOG" | head -6 || sed -n '1,12p' "$TMP_LOG"
    fail=1
  fi
done

step "secret audit (working tree)"
python3 scripts/audit-secrets.py --no-history || fail=1

step "python syntax"
for f in scripts/*.py; do
  printf '  %-40s' "$f"
  if python3 -m py_compile "$f"; then echo ok; else fail=1; fi
done

step "helm lint"
helm lint charts/litellm --set existingSecret=ci-secret || fail=1

step "helm template"
helm template litellm charts/litellm --namespace litellm --set existingSecret=ci-secret >/dev/null || fail=1

step "docs"
python3 ./scripts/check-docs.py || fail=1

step "monitoring"
python3 ./scripts/check-monitoring.py || fail=1

if command -v shellcheck >/dev/null 2>&1; then
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
