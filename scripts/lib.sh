#!/usr/bin/env bash
# Shared helpers for the deployment scripts.
set -euo pipefail

readonly C_RESET='\033[0m'
readonly C_INFO='\033[0;36m'
readonly C_OK='\033[0;32m'
readonly C_WARN='\033[0;33m'
readonly C_ERR='\033[0;31m'

log() { printf '%b[%s]%b %s\n' "$C_INFO" "$(date +%H:%M:%S)" "$C_RESET" "$*" >&2; }
ok() { printf '%b[ ok ]%b %s\n' "$C_OK" "$C_RESET" "$*" >&2; }
warn() { printf '%b[warn]%b %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die() {
  printf '%b[fail]%b %s\n' "$C_ERR" "$C_RESET" "$*" >&2
  exit 1
}

require() {
  local missing=0 tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'missing dependency: %s\n' "$tool" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || die "install the missing tools and retry (see docs/deployment.md)"
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

# Credentials live in exactly one place: secrets/hw.env, written by creds.sh.
# Variables already in the environment win, so CI can inject them without a file.
# Called explicitly (not at source time) so `creds.sh check` sees the raw state.
load_credentials() {
  local file key value
  file="$(repo_root)/secrets/hw.env"
  [ -f "$file" ] || return 0
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in '' | '#'*) continue ;; esac
    value="${value%\"}"
    value="${value#\"}"
    [ -n "${!key:-}" ] || export "$key=$value"
  done <"$file"
}

# terraform_output <dir> <name>
terraform_output() {
  local dir="$1" name="$2"
  terraform -chdir="$dir" output -raw "$name"
}

# terraform_output_json <dir> <name>
terraform_output_json() {
  local dir="$1" name="$2"
  terraform -chdir="$dir" output -json "$name"
}
