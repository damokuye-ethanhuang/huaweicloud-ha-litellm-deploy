#!/usr/bin/env bash
# Destroy the infrastructure. Requires an explicit confirmation because the
# database is deleted with it.
#
#   CONFIRM=yes ./scripts/destroy.sh [example-dir]
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

TF_DIR="${1:-terraform/examples/cce-ha}"

require terraform

if [ "${CONFIRM:-}" != "yes" ]; then
  die "refusing to destroy without CONFIRM=yes (this deletes RDS, DCS, CCE and the VPC)"
fi

if [ -f "$TF_DIR/terraform.tfstate" ]; then
  warn "state contains plaintext secrets (generated passwords). Destroy removes them from the cloud, not from backups of the state."
fi

log "terraform destroy ($TF_DIR)"
terraform -chdir="$TF_DIR" destroy -input=false
ok "destroyed"

# The stack is gone; the customer's credentials should not outlive the test.
if ! "$(dirname "$0")/handoff.py" check >/dev/null 2>&1; then
  warn "customer data still on disk: run ./scripts/handoff.py scrub"
fi
