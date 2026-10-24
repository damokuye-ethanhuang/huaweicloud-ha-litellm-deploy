#!/usr/bin/env bash
# Compatibility shim. The application deployment lives in scripts/deploy.sh
# (stage `deploy-app`) so there is exactly one implementation: it merges the
# model list rendered by preflight with the runtime ELB/image values.
#
#   ./scripts/deploy-app.sh              # local, needs cluster access
#   ./scripts/deploy-app.sh --remote     # via the bastion (no cluster access here)
set -euo pipefail
exec "$(dirname "$0")/deploy.sh" "$@" deploy-app
