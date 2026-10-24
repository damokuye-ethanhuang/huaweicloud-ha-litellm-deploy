#!/usr/bin/env bash
# Run the in-cluster stages from a machine that cannot reach the cluster.
#
#   ./scripts/remote-deploy.sh bundle          # render out/bastion/ locally
#   ./scripts/remote-deploy.sh push            # upload to the bastion
#   ./scripts/remote-deploy.sh deploy-app      # helm install, executed ON the bastion
#   ./scripts/remote-deploy.sh verify          # smoke test, executed ON the bastion
#   ./scripts/remote-deploy.sh all             # bundle + push + deploy-app + verify
#
# Why: the CCE API has no public endpoint and the ELB is internal, so a laptop
# outside the VPC can create infrastructure (cloud APIs are public) but cannot
# reach the cluster or the gateway. The bastion is the only public host, so
# everything in-cluster is executed there.
#
# The bundle is self-contained: rendered Helm values, the chart, the Secret
# contents, the kubeconfig and the smoke test. The bastion therefore needs only
# kubectl and helm - no Terraform, no cloud credentials, no repo clone.
#
# Environment:
#   BASTION_HOST / BASTION_USER / BASTION_KEY / BASTION_PASSWORD   (ssh access)
#   NAMESPACE (litellm), RELEASE (litellm), HELM_TIMEOUT (25m)
#   TF_DIR, OUT_DIR
set -euo pipefail

# shellcheck source=scripts/lib.sh
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPO="$(repo_root)"
TF_DIR="${TF_DIR:-$REPO/terraform/examples/cce-ha}"
OUT_DIR="${OUT_DIR:-$REPO/out}"
BUNDLE_DIR="$OUT_DIR/bastion"
NAMESPACE="${NAMESPACE:-litellm}"
RELEASE="${RELEASE:-litellm}"
HELM_TIMEOUT="${HELM_TIMEOUT:-25m}"
BASTION_USER="${BASTION_USER:-root}"
REMOTE_DIR="${REMOTE_DIR:-/root/litellm-bundle}"
PROVIDER_ENV_FILE="${PROVIDER_ENV_FILE:-$REPO/secrets/app.env}"

remote_host() {
  local host="${BASTION_HOST:-}"
  if [ -z "$host" ]; then
    host="$(terraform -chdir="$TF_DIR" output -json bastion 2>/dev/null | jq -r '.public_ip // empty' || true)"
  fi
  [ -n "$host" ] || die "BASTION_HOST is empty and terraform output bastion.public_ip is not available (is bastion_enabled = false?)"
  printf '%s' "$host"
}

setup_ssh() {
  local host
  host="$(remote_host)"
  SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30)
  if [ -n "${BASTION_KEY:-}" ]; then
    [ -f "$BASTION_KEY" ] || die "BASTION_KEY does not exist: $BASTION_KEY"
    SSH_TARGET=(-i "$BASTION_KEY" "${BASTION_USER}@${host}")
    SSH_BIN=(ssh)
  elif [ -n "${BASTION_PASSWORD:-}" ]; then
    command -v sshpass >/dev/null 2>&1 || die "sshpass is required when using BASTION_PASSWORD"
    SSH_TARGET=("${BASTION_USER}@${host}")
    SSH_BIN=(sshpass -p "$BASTION_PASSWORD" ssh)
  else
    die "set BASTION_KEY (recommended) or BASTION_PASSWORD"
  fi
  REMOTE_HOST="$host"
}

# ---------------------------------------------------------------- bundle
cmd_bundle() {
  require terraform jq python3
  [ -f "$OUT_DIR/helm-values.yaml" ] || die "out/helm-values.yaml missing; run './scripts/deploy.sh preflight' first"

  log "rendering bundle into $BUNDLE_DIR"
  rm -rf "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR"

  local elb cert image gateway
  elb="$(terraform_output "$TF_DIR" loadbalancer_id)"
  cert="$(terraform_output "$TF_DIR" certificate_id)"
  image="$(terraform_output "$TF_DIR" litellm_image)"
  gateway="$(terraform_output "$TF_DIR" gateway_private_ip)"
  [ -n "$elb" ] || die "loadbalancer_id is empty; did apply-infra finish?"

  # Helm values: rendered models/fallbacks + runtime ELB annotations + image.
  python3 - "$OUT_DIR/helm-values.yaml" "$BUNDLE_DIR/values.yaml" \
    "$image" "$elb" "$cert" <<'PY'
import sys
import yaml

src, dst, image, elb, cert = sys.argv[1:6]
values = yaml.safe_load(open(src, encoding="utf-8")) or {}
repo, _, tag = image.rpartition(":")
values.setdefault("image", {}).update({"repository": repo, "tag": tag})
annotations = {
    "kubernetes.io/elb.id": elb,
    "kubernetes.io/elb.class": "performance",
    "kubernetes.io/elb.port": "443",
}
if cert:
    annotations["kubernetes.io/elb.protocol-port"] = "https:443"
    annotations["kubernetes.io/elb.cert-id"] = cert
else:
    annotations["kubernetes.io/elb.protocol-port"] = "http:443"
values.setdefault("service", {}).update(
    {"type": "LoadBalancer", "port": 443, "annotations": annotations}
)
yaml.safe_dump(values, open(dst, "w", encoding="utf-8"), sort_keys=False)
PY

  # Secret contents: Terraform-generated first, provider keys last so an
  # operator-supplied value wins.
  terraform_output_json "$TF_DIR" app_env |
    jq -r 'to_entries[] | "\(.key)=\(.value)"' >"$BUNDLE_DIR/app.env"
  if [ -f "$PROVIDER_ENV_FILE" ]; then
    log "merging provider keys from $PROVIDER_ENV_FILE"
    cat "$PROVIDER_ENV_FILE" >>"$BUNDLE_DIR/app.env"
  else
    warn "no $PROVIDER_ENV_FILE; model endpoints that authenticate will fail until keys are provided"
  fi
  chmod 600 "$BUNDLE_DIR/app.env"

  terraform -chdir="$TF_DIR" output -raw kube_config_raw >"$BUNDLE_DIR/kubeconfig"
  chmod 600 "$BUNDLE_DIR/kubeconfig"

  cp -R "$REPO/charts/litellm" "$BUNDLE_DIR/chart"
  cp "$REPO/scripts/smoke-test.sh" "$REPO/scripts/lib.sh" "$BUNDLE_DIR/"

  printf 'NAMESPACE=%s\nRELEASE=%s\nHELM_TIMEOUT=%s\nGATEWAY=%s\n' \
    "$NAMESPACE" "$RELEASE" "$HELM_TIMEOUT" "$gateway" >"$BUNDLE_DIR/meta.env"

  # Everything the bastion executes lives here; it needs only kubectl + helm.
  cat >"$BUNDLE_DIR/install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./meta.env

export KUBECONFIG="$PWD/kubeconfig"
command -v kubectl >/dev/null || { echo "kubectl missing on bastion" >&2; exit 1; }
command -v helm >/dev/null || { echo "helm missing on bastion" >&2; exit 1; }

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  kubectl get ns >/dev/null 2>&1 && break
  echo "waiting for the cluster API (attempt $attempt)"; sleep 10
done

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
kubectl -n "$NAMESPACE" create secret generic litellm-secrets \
  --from-env-file=./app.env --dry-run=client -o yaml | kubectl apply -f - >/dev/null

helm upgrade --install "$RELEASE" ./chart \
  --namespace "$NAMESPACE" --values ./values.yaml \
  --wait --timeout "$HELM_TIMEOUT"
echo "release $RELEASE applied; gateway VIP: $GATEWAY"
SH
  chmod +x "$BUNDLE_DIR/install.sh"

  ok "bundle ready: $BUNDLE_DIR"
}

# ---------------------------------------------------------------- push
cmd_push() {
  setup_ssh
  [ -d "$BUNDLE_DIR" ] || die "no bundle; run './scripts/remote-deploy.sh bundle' first"
  log "uploading bundle to ${REMOTE_HOST}:${REMOTE_DIR}"
  tar czf - -C "$BUNDLE_DIR" . |
    "${SSH_BIN[@]}" "${SSH_OPTS[@]}" "${SSH_TARGET[@]}" \
      "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR' && tar xzf - -C '$REMOTE_DIR' && chmod 700 '$REMOTE_DIR' && chmod 600 '$REMOTE_DIR'/app.env '$REMOTE_DIR'/kubeconfig && echo uploaded"
  ok "bundle uploaded"
}

# ---------------------------------------------------------------- run
cmd_run() {
  local stage="$1"
  setup_ssh
  case "$stage" in
    deploy-app)
      log "executing helm install on ${REMOTE_HOST}"
      "${SSH_BIN[@]}" "${SSH_OPTS[@]}" "${SSH_TARGET[@]}" "bash '$REMOTE_DIR/install.sh'"
      ;;
    verify)
      # The VIP is internal: run the probe where it is routable.
      local gateway
      gateway="$(bundle_gateway)"
      log "executing smoke test on ${REMOTE_HOST} against ${gateway}"
      "${SSH_BIN[@]}" "${SSH_OPTS[@]}" "${SSH_TARGET[@]}" \
        "cd '$REMOTE_DIR' && set -a && . ./app.env && set +a && KUBECONFIG=\$PWD/kubeconfig ./smoke-test.sh '$gateway'"
      ;;
    *)
      die "unknown remote stage: $stage"
      ;;
  esac
}

bundle_gateway() {
  # Parsed rather than sourced: meta.env is data, and sourcing it would rely on
  # the caller never injecting a line.
  local gateway
  [ -f "$BUNDLE_DIR/meta.env" ] || die "no bundle metadata; run 'bundle' first"
  gateway="$(sed -n 's/^GATEWAY=//p' "$BUNDLE_DIR/meta.env")"
  [ -n "$gateway" ] || die "bundle metadata has no GATEWAY"
  printf '%s' "$gateway"
}

case "${1:-all}" in
  bundle) cmd_bundle ;;
  push) cmd_push ;;
  deploy-app | verify) cmd_run "$1" ;;
  all)
    cmd_bundle
    cmd_push
    cmd_run deploy-app
    cmd_run verify
    ;;
  *)
    die "usage: remote-deploy.sh [bundle|push|deploy-app|verify|all]"
    ;;
esac
