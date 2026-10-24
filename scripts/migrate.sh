#!/usr/bin/env bash
# Break-glass: run schema migrations and spend-log indexing as a one-off job.
# The Helm release already runs this as a pre-install/pre-upgrade hook; use this
# script when a release failed midway and you need to finish the migration.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPO_ROOT="$(repo_root)"
TF_DIR="${TF_DIR:-$REPO_ROOT/terraform/examples/cce-ha}"
NAMESPACE="${NAMESPACE:-litellm}"
RELEASE="${RELEASE:-litellm}"
CHART="${CHART:-$REPO_ROOT/charts/litellm}"
SECRET_NAME="${SECRET_NAME:-litellm-secrets}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/litellm-cce.yaml}"

require terraform helm kubectl

export KUBECONFIG="$KUBECONFIG_FILE"
[ -f "$KUBECONFIG" ] || die "kubeconfig not found: $KUBECONFIG_FILE (run scripts/deploy-app.sh first)"

log "removing previous manual migration jobs"
kubectl -n "$NAMESPACE" delete job -l app.kubernetes.io/component=migration --ignore-not-found >/dev/null

log "applying migration job from the chart"
helm template "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --set existingSecret="$SECRET_NAME" \
  --show-only templates/migration-job.yaml |
  kubectl -n "$NAMESPACE" apply -f -

log "waiting for completion (up to 30 minutes)"
kubectl -n "$NAMESPACE" wait --for=condition=complete job \
  -l app.kubernetes.io/component=migration --timeout=30m

ok "migration finished - check the logs above before rolling the deployment"
