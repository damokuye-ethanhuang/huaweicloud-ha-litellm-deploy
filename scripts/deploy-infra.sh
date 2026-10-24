#!/usr/bin/env bash
# Provision the Huawei Cloud infrastructure with Terraform.
#
#   ./scripts/deploy-infra.sh [plan|apply] [example-dir]
#
# Credentials are read from HW_ACCESS_KEY / HW_SECRET_KEY (or a standard
# ~/.huaweicloud/credentials file). Never pass them as variables.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ACTION="${1:-plan}"
TF_DIR="${2:-terraform/examples/cce-ha}"

require terraform jq
[ -d "$TF_DIR" ] || die "terraform directory not found: $TF_DIR"

if [ -z "${HW_ACCESS_KEY:-}" ] || [ -z "${HW_SECRET_KEY:-}" ]; then
  warn "HW_ACCESS_KEY/HW_SECRET_KEY are not set; the provider will fall back to ~/.huaweicloud/credentials"
fi

if [ ! -f "$TF_DIR/terraform.tfvars" ] && [ -f "$TF_DIR/terraform.tfvars.example" ]; then
  warn "$TF_DIR/terraform.tfvars is missing; copy terraform.tfvars.example and edit it first"
fi

log "terraform init ($TF_DIR)"
terraform -chdir="$TF_DIR" init -input=false -upgrade

case "$ACTION" in
  plan)
    log "terraform plan"
    terraform -chdir="$TF_DIR" plan -input=false -out=tfplan
    ok "plan written to $TF_DIR/tfplan - review it before applying"
    ;;
  apply)
    if [ ! -f "$TF_DIR/tfplan" ]; then
      log "no saved plan found, creating one"
      terraform -chdir="$TF_DIR" plan -input=false -out=tfplan
    fi
    log "terraform apply (CCE creation can take 20-40 minutes)"
    terraform -chdir="$TF_DIR" apply -input=false tfplan
    ok "infrastructure ready"
    terraform -chdir="$TF_DIR" output
    ;;
  *)
    die "unknown action: $ACTION (expected plan or apply)"
    ;;
esac
