#!/usr/bin/env bash
# The AK/SK lifecycle: one file, filled by the operator, cleared after a test.
#
#   ./scripts/creds.sh path           where the file is
#   ./scripts/creds.sh set            type them in (no echo, chmod 600)
#   ./scripts/creds.sh set --from-env import HW_ACCESS_KEY/HW_SECRET_KEY already exported
#   ./scripts/creds.sh status         masked view of what preflight will use
#   ./scripts/creds.sh load           export them into the current shell: eval "$(... load)"
#   ./scripts/creds.sh check          exit 1 when real credentials are still present
#   ./scripts/creds.sh clear          put the file back to placeholders
#
# The file is secrets/hw.env (gitignored). Environment variables still win, so a
# CI runner can inject credentials without writing anything to disk.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(repo_root)"
ENV_FILE="$SECRETS_DIR/hw.env"
TEMPLATE="$ROOT/secrets/hw.env.example"

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# A pasted key commonly carries a trailing space or a CR from a Windows copy.
# The signature failure that causes is invisible later, so normalise it here and
# tell the operator instead of failing at plan time.
normalise() {
  printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

mask() {
  local value="$1"
  if [ -z "$value" ]; then
    printf '(empty)'
  elif [ "${#value}" -le 8 ]; then
    printf '****'
  else
    printf '%s...%s' "${value:0:4}" "${value: -4}"
  fi
}

# Read KEY=VALUE without sourcing: the file is data, not shell code.
file_value() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  awk -F= -v k="$key" '
    /^[[:space:]]*#/ { next }
    $1 == k { sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit }
  ' "$ENV_FILE"
}

effective() {
  local key="$1"
  local from_env="${!key:-}"
  if [ -n "$from_env" ]; then printf '%s' "$from_env"; else file_value "$key"; fi
}

cmd_path() { printf '%s\n' "$ENV_FILE"; }

cmd_status() {
  local ak sk project source
  ak="$(effective HW_ACCESS_KEY)"
  sk="$(effective HW_SECRET_KEY)"
  project="$(effective HW_PROJECT_ID)"
  source="file"
  [ -n "${HW_ACCESS_KEY:-}" ] && source="environment"

  printf 'credentials file  %s\n' "$ENV_FILE"
  printf '                 %s\n' "$([ -f "$ENV_FILE" ] && echo present || echo 'missing (run: creds.sh set)')"
  printf 'source           %s\n' "$source"
  printf 'HW_ACCESS_KEY    %s\n' "$(mask "$ak")"
  printf 'HW_SECRET_KEY    %s\n' "$(mask "$sk")"
  printf 'HW_PROJECT_ID    %s\n' "${project:-(default project)}"
  printf 'state            %s\n' "$(state_word)"
}

state_word() {
  local ak sk
  ak="$(effective HW_ACCESS_KEY)"
  sk="$(effective HW_SECRET_KEY)"
  if [ -n "$ak" ] && [ -n "$sk" ]; then echo "configured"; else echo "not configured"; fi
}

cmd_set() {
  local from_env=0
  [ "${1:-}" = "--from-env" ] && from_env=1

  local ak sk project
  if [ "$from_env" -eq 1 ]; then
    ak="${HW_ACCESS_KEY:-}"
    sk="${HW_SECRET_KEY:-}"
    project="${HW_PROJECT_ID:-}"
    if [ -z "$ak" ] || [ -z "$sk" ]; then
      die "HW_ACCESS_KEY / HW_SECRET_KEY are not exported"
    fi
  else
    [ -t 0 ] || die "stdin is not a terminal; use --from-env or edit $ENV_FILE"
    printf 'AK (input is hidden): ' >&2
    IFS= read -rs ak
    printf '\n' >&2
    printf 'SK (input is hidden): ' >&2
    IFS= read -rs sk
    printf '\n' >&2
    printf 'project id [blank = default project]: ' >&2
    IFS= read -r project
  fi

  if [ -z "$ak" ] || [ -z "$sk" ]; then
    die "both AK and SK are required"
  fi

  local clean_ak clean_sk
  clean_ak="$(normalise "$ak")"
  clean_sk="$(normalise "$sk")"
  if [ "$clean_ak" != "$ak" ] || [ "$clean_sk" != "$sk" ]; then
    warn "stripped surrounding whitespace/CR from the pasted value"
    ak="$clean_ak"
    sk="$clean_sk"
  fi

  umask 077
  {
    printf '# Written by scripts/creds.sh on %s. Gitignored; clear it after testing.\n' "$(date -Iseconds)"
    printf 'HW_ACCESS_KEY=%s\n' "$ak"
    printf 'HW_SECRET_KEY=%s\n' "$sk"
    printf 'HW_PROJECT_ID=%s\n' "$project"
  } >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "stored in $ENV_FILE (AK $(mask "$ak"))"
  warn "after testing run: ./scripts/creds.sh clear"
}

cmd_load() {
  local ak sk project
  ak="$(effective HW_ACCESS_KEY)"
  sk="$(effective HW_SECRET_KEY)"
  project="$(effective HW_PROJECT_ID)"
  if [ -z "$ak" ] || [ -z "$sk" ]; then
    die "no credentials in $ENV_FILE"
  fi
  printf 'export HW_ACCESS_KEY=%q\n' "$ak"
  printf 'export HW_SECRET_KEY=%q\n' "$sk"
  [ -n "$project" ] && printf 'export HW_PROJECT_ID=%q\n' "$project"
  return 0
}

cmd_clear() {
  if [ -f "$ENV_FILE" ]; then
    rm -f "$ENV_FILE"
    ok "removed $ENV_FILE"
  else
    ok "already clear (no $ENV_FILE)"
  fi
  [ -f "$TEMPLATE" ] || warn "template missing: $TEMPLATE"
}

cmd_check() {
  local ak sk
  ak="$(effective HW_ACCESS_KEY)"
  sk="$(effective HW_SECRET_KEY)"
  # Environment variables count too: a test shell with them exported is still a
  # live credential, even though nothing is on disk.
  if [ -n "$ak" ] || [ -n "$sk" ]; then
    printf '[fail] live credentials still present (%s)\n' "$(state_word)" >&2
    printf '       run: ./scripts/creds.sh clear%s\n' \
      "$([ -n "${HW_ACCESS_KEY:-}${HW_SECRET_KEY:-}" ] && echo '; unset HW_ACCESS_KEY HW_SECRET_KEY')" >&2
    return 1
  fi
  ok "no credentials in $ENV_FILE and none exported"
}

case "${1:-status}" in
  path) cmd_path ;;
  status) cmd_status ;;
  set) shift; cmd_set "${1:-}" ;;
  load) cmd_load ;;
  clear) cmd_clear ;;
  check) cmd_check ;;
  -h | --help | help) usage ;;
  *) usage; exit 2 ;;
esac
