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
