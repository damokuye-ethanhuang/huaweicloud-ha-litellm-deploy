#!/usr/bin/env bash
# Thin wrapper so both `./scripts/preflight.sh` and `./scripts/deploy.sh preflight`
# work. Real logic lives in preflight.py.
set -euo pipefail
exec python3 "$(dirname "$0")/preflight.py" "$@"
