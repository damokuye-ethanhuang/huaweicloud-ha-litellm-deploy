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

# Fails fast instead of after 20 minutes of teardown: ELB.8917 leaves the VPC
# half-deleted and the load balancer charging until someone clears the flag.
if grep -qE '^[[:space:]]*elb_deletion_protection[[:space:]]*=[[:space:]]*true' "$TF_DIR/terraform.tfvars" 2>/dev/null; then
  die "elb_deletion_protection = true will block destroy with ELB.8917. Set it to false and run 'terraform apply' once (it is an in-place update), then destroy."
fi

# The Ingress owns the ELB in the default mode: deleting the namespace first is
# what removes the load balancer, and it keeps the VPC from hanging on an ENI.
if grep -qE '^[[:space:]]*elb_mode[[:space:]]*=[[:space:]]*"ingress"' "$TF_DIR/terraform.tfvars" 2>/dev/null; then
  log "elb_mode = ingress: the ELB is owned by the Ingress and disappears with the cluster; nothing extra to delete here"
fi

# Terraform deletes RDS before it deletes the cluster, and a running pod pool
# makes that fail with "DBS.1010155 Other users are accessing the database" -
# after which the VPC is half gone and the cluster keeps billing. Uninstall the
# release first so the connections are actually closed.
uninstall_release() {
  local kubeconfig="${KUBECONFIG:-$HOME/.kube/litellm-gateway.yaml}"
  if [ ! -f "$kubeconfig" ]; then
    log "no kubeconfig at $kubeconfig: skipping helm uninstall"
    return 0
  fi
  if ! command -v helm >/dev/null 2>&1; then
    warn "helm missing: skipping the release uninstall (RDS deletion may fail with DBS.1010155)"
    return 0
  fi
  if ! KUBECONFIG="$kubeconfig" helm status litellm -n litellm >/dev/null 2>&1; then
    log "no helm release 'litellm' in namespace litellm"
    return 0
  fi
  log "helm uninstall litellm (closes the DB pools before RDS is deleted)"
  KUBECONFIG="$kubeconfig" helm uninstall litellm -n litellm --wait --timeout 5m \
    || warn "helm uninstall failed; continuing - destroy may hit DBS.1010155"
  for _ in $(seq 1 24); do
    if [ -z "$(KUBECONFIG="$kubeconfig" kubectl -n litellm get pods -o name 2>/dev/null)" ]; then
      return 0
    fi
    sleep 5
  done
  warn "pods still present after 2 minutes; RDS deletion may fail"
}

log "terraform destroy ($TF_DIR)"
uninstall_release
terraform -chdir="$TF_DIR" destroy -input=false
ok "destroyed"

# The stack is gone; the customer's credentials should not outlive the test.
if ! "$(dirname "$0")/handoff.py" check >/dev/null 2>&1; then
  warn "customer data still on disk: run ./scripts/handoff.py scrub"
fi
