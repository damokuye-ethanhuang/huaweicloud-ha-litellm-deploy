#!/usr/bin/env bash
# Create the namespace and the application Secret, then install/upgrade the chart.
#
#   ./scripts/deploy-app.sh
#
# Optional: put provider keys in secrets/app.env (gitignored), one KEY=VALUE per
# line. They are merged into the Kubernetes Secret on every deploy.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPO_ROOT="$(repo_root)"
TF_DIR="${TF_DIR:-$REPO_ROOT/terraform/examples/cce-ha}"
NAMESPACE="${NAMESPACE:-litellm}"
RELEASE="${RELEASE:-litellm}"
CHART="${CHART:-$REPO_ROOT/charts/litellm}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/litellm-cce.yaml}"
SECRET_NAME="${SECRET_NAME:-litellm-secrets}"
PROVIDER_ENV_FILE="${PROVIDER_ENV_FILE:-$REPO_ROOT/secrets/app.env}"
HELM_TIMEOUT="${HELM_TIMEOUT:-20m}"

require terraform helm kubectl jq

[ -d "$TF_DIR" ] || die "terraform directory not found: $TF_DIR"

log "writing kubeconfig to $KUBECONFIG_FILE"
mkdir -p "$(dirname "$KUBECONFIG_FILE")"
terraform -chdir="$TF_DIR" output -raw kube_config_raw >"$KUBECONFIG_FILE"
chmod 600 "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

ELB_ID="$(terraform_output "$TF_DIR" loadbalancer_id)"
CERT_ID="$(terraform_output "$TF_DIR" certificate_id)"
PUBLIC_IP="$(terraform_output "$TF_DIR" elb_public_ip)"
APP_ENV_JSON="$(terraform_output_json "$TF_DIR" app_env)"
APP_IMAGE="$(terraform_output "$TF_DIR" litellm_image)"
IMAGE_REPOSITORY="${APP_IMAGE%:*}"
IMAGE_TAG="${APP_IMAGE##*:}"

DB_URL="$(jq -r '.DATABASE_URL' <<<"$APP_ENV_JSON")"
MASTER_KEY="$(jq -r '.LITELLM_MASTER_KEY' <<<"$APP_ENV_JSON")"
SALT_KEY="$(jq -r '.LITELLM_SALT_KEY' <<<"$APP_ENV_JSON")"
REDIS_HOST="$(jq -r '.REDIS_HOST' <<<"$APP_ENV_JSON")"
REDIS_PORT="$(jq -r '.REDIS_PORT' <<<"$APP_ENV_JSON")"
REDIS_PASSWORD="$(jq -r '.REDIS_PASSWORD' <<<"$APP_ENV_JSON")"
REDIS_SSL="$(jq -r '.REDIS_SSL' <<<"$APP_ENV_JSON")"

log "namespace $NAMESPACE"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

secret_args=(
  --from-literal=DATABASE_URL="$DB_URL"
  --from-literal=LITELLM_MASTER_KEY="$MASTER_KEY"
  --from-literal=LITELLM_SALT_KEY="$SALT_KEY"
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD"
)

if [ -f "$PROVIDER_ENV_FILE" ]; then
  log "merging provider keys from $PROVIDER_ENV_FILE"
  secret_args+=(--from-env-file="$PROVIDER_ENV_FILE")
else
  warn "no $PROVIDER_ENV_FILE found; provider API keys are not configured yet"
fi

log "secret $SECRET_NAME"
kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  "${secret_args[@]}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

VALUES_FILE="$(mktemp)"
trap 'rm -f "$VALUES_FILE"' EXIT

if [ -n "$CERT_ID" ]; then
  annotations=$(jq -n --arg elb "$ELB_ID" --arg cert "$CERT_ID" '{
    "kubernetes.io/elb.id": $elb,
    "kubernetes.io/elb.class": "performance",
    "kubernetes.io/elb.port": "443",
    "kubernetes.io/elb.protocol-port": "https:443",
    "kubernetes.io/elb.cert-id": $cert
  }')
else
  warn "no certificate configured; the load balancer listener will speak plain HTTP"
  annotations=$(jq -n --arg elb "$ELB_ID" '{
    "kubernetes.io/elb.id": $elb,
    "kubernetes.io/elb.class": "performance",
    "kubernetes.io/elb.port": "443",
    "kubernetes.io/elb.protocol-port": "http:443"
  }')
fi

jq -n \
  --arg secret "$SECRET_NAME" \
  --arg redis_host "$REDIS_HOST" \
  --arg redis_port "$REDIS_PORT" \
  --arg redis_ssl "$REDIS_SSL" \
  --arg image_repository "$IMAGE_REPOSITORY" \
  --arg image_tag "$IMAGE_TAG" \
  --argjson annotations "$annotations" \
  '{
    existingSecret: $secret,
    image: {repository: $image_repository, tag: $image_tag},
    service: {type: "LoadBalancer", port: 443, annotations: $annotations},
    env: {
      STORE_MODEL_IN_DB: "True",
      DISABLE_SCHEMA_UPDATE: "true",
      REDIS_HOST: $redis_host,
      REDIS_PORT: $redis_port,
      REDIS_SSL: $redis_ssl
    }
  }' >"$VALUES_FILE"

log "helm upgrade --install $RELEASE"
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --values "$VALUES_FILE" \
  --wait \
  --timeout "$HELM_TIMEOUT"

ok "gateway deployed"

log "waiting for the load balancer address (up to 5 minutes)"
for _ in $(seq 1 60); do
  ingress_ip="$(kubectl -n "$NAMESPACE" get service "$RELEASE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$ingress_ip" ] && break
  sleep 5
done

if [ -n "$PUBLIC_IP" ]; then
  if [ -n "$CERT_ID" ]; then
    ok "endpoint: https://$PUBLIC_IP"
  else
    warn "endpoint: http://$PUBLIC_IP (no TLS configured)"
  fi
fi

"$REPO_ROOT/scripts/smoke-test.sh" || warn "smoke test failed - inspect the migration job and pod logs"
