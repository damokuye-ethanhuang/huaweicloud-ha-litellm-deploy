#!/usr/bin/env bash
# Fail when config/litellm-config.yaml and the chart copy drift apart.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/config/litellm-config.yaml"
DST="$REPO_ROOT/charts/litellm/files/litellm-config.yaml"

if ! diff -u "$SRC" "$DST"; then
  # shellcheck disable=SC2016  # backticks are literal instructions, not a command
  printf '\nconfig drift detected: run `make sync-config` and commit the result\n' >&2
  exit 1
fi
