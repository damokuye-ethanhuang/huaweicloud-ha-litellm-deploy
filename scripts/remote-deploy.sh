#!/usr/bin/env bash
# Run the in-cluster stages from a machine that cannot reach the cluster.
#
#   ./scripts/remote-deploy.sh bundle          # render $OUT_DIR/bastion/ locally
#   ./scripts/remote-deploy.sh push            # upload to the bastion
#   ./scripts/remote-deploy.sh deploy-app      # helm install, executed ON the bastion
#   ./scripts/remote-deploy.sh verify          # smoke test, executed ON the bastion
#   ./scripts/remote-deploy.sh all             # bundle + push + deploy-app + verify
#   ./scripts/remote-deploy.sh exec <command>  # ad-hoc command on the bastion
#   ./scripts/remote-deploy.sh put <local>:<remote>
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
# Terraform generates the keypair and `deploy.sh bastion-key` writes it here, so
# default to it: requiring an export on every call is how the operator ends up
# with a half-configured shell and a stage that "cannot find the bastion".
if [ -z "${BASTION_KEY:-}" ] && [ -z "${BASTION_PASSWORD:-}" ] && [ -f "$STATE_DIR/bastion_key" ]; then
  BASTION_KEY="$STATE_DIR/bastion_key"
fi
REMOTE_DIR="${REMOTE_DIR:-/root/litellm-bundle}"
PROVIDER_ENV_FILE="${PROVIDER_ENV_FILE:-$SECRETS_DIR/app.env}"

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
  [ -f "$OUT_DIR/helm-values.yaml" ] || die "$OUT_DIR/helm-values.yaml missing; run './scripts/deploy.sh preflight' first"

  log "rendering bundle into $BUNDLE_DIR"
  rm -rf "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR"

  local elb cert image gateway mode ingress
  mode="$(terraform_output "$TF_DIR" elb_mode)"
  ingress="$(terraform_output_json "$TF_DIR" ingress_elb)"
  elb="$(terraform_output "$TF_DIR" loadbalancer_id)"
  cert="$(terraform_output "$TF_DIR" certificate_id)"
  image="$(terraform_output "$TF_DIR" litellm_image)"
  # Null in ingress mode (the Ingress controller allocates the VIP after apply),
  # and terraform errors on a null output rather than printing nothing.
  gateway="$(terraform_output "$TF_DIR" gateway_private_ip 2>/dev/null || true)"
  if [ "$mode" = "standalone" ] && [ -z "$elb" ]; then
    die "loadbalancer_id is empty; did apply-infra finish?"
  fi

  # Same guard as deploy.sh: the bundle is executed on the bastion, but the
  # pods pull from the nodes, which have no public egress.
  case "$image" in
    swr.*.myhuaweicloud.com/*) ;;
    ghcr.io/*|docker.io/*|ghcr.nju.edu.cn/*)
      die "image is '$image' but the supply chain is swr: run scripts/mirror-image.sh on the bastion first"
      ;;
  esac

  # Helm values: rendered models/fallbacks + ELB/Ingress wiring + image. One
  # renderer for both paths, so the bastion applies exactly what deploy.sh would.
  python3 "$REPO/scripts/render-helm-values.py" \
    --src "$OUT_DIR/helm-values.yaml" \
    --dst "$BUNDLE_DIR/values.yaml" \
    --image "$image" \
    --mode "$mode" \
    --elb-id "$elb" \
    --cert-id "$cert" \
    --ingress-json "$ingress"

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

  # SWR pull secret: pods authenticate against the intranet SWR endpoint with
  # the 24h temporary login. Fetched here (AK/SK live on the operator machine);
  # the bastion gets only the resulting credential, never the AK/SK.
  if [ "${image#swr.}" != "$image" ]; then
    log "fetching SWR pull credential (valid 24h)"
    SWR_REGION="${image#swr.}"; SWR_REGION="${SWR_REGION%%.*}"
    if creds="$(SWR_REGION="$SWR_REGION" "$REPO/scripts/mirror-image.sh" --print-creds)"; then
      printf '%s\n' "$creds" >"$BUNDLE_DIR/swr-cred.env"
      chmod 600 "$BUNDLE_DIR/swr-cred.env"
    else
      warn "could not fetch SWR credential: $creds - create the pull secret manually (docs/deployment.md §8)"
    fi
  fi

  printf 'NAMESPACE=%s\nRELEASE=%s\nHELM_TIMEOUT=%s\nGATEWAY=%s\nELB_MODE=%s\nCERT_ID=%s\nIMAGE_REPOSITORY=%s\n' \
    "$NAMESPACE" "$RELEASE" "$HELM_TIMEOUT" "$gateway" "$mode" "$cert" "${image%:*}" >"$BUNDLE_DIR/meta.env"

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

# Refresh the SWR pull secret when the bundle carries a fresh credential;
# pods pull over the intranet and cannot fall back to a public registry.
if [ -f ./swr-cred.env ]; then
  read -r swr_user swr_pass < ./swr-cred.env
  if [ -n "$swr_user" ] && [ -n "$swr_pass" ]; then
    swr_server="$(printf '%s' "$IMAGE_REPOSITORY" | sed 's#/.*##')"
    kubectl -n "$NAMESPACE" create secret docker-registry swr-cred \
      --docker-server="$swr_server" \
      --docker-username="$swr_user" --docker-password="$swr_pass" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "swr pull secret refreshed (expires in 24h)"
  fi
fi

helm upgrade --install "$RELEASE" ./chart \
  --namespace "$NAMESPACE" --values ./values.yaml \
  --set existingSecret=litellm-secrets \
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
      "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR' && tar xzf - -C '$REMOTE_DIR' && chmod 700 '$REMOTE_DIR' && chmod 600 '$REMOTE_DIR'/app.env '$REMOTE_DIR'/kubeconfig '$REMOTE_DIR'/swr-cred.env 2>/dev/null || true && echo uploaded"
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
  local gateway mode namespace
  [ -f "$BUNDLE_DIR/meta.env" ] || die "no bundle metadata; run 'bundle' first"
  gateway="$(sed -n 's/^GATEWAY=//p' "$BUNDLE_DIR/meta.env")"
  if [ -z "$gateway" ]; then
    # Ingress mode: Terraform has no VIP. Ask the cluster - the ELB only exists
    # after the CCE Ingress controller has reconciled the Ingress.
    mode="$(sed -n 's/^ELB_MODE=//p' "$BUNDLE_DIR/meta.env")"
    [ "$mode" = "ingress" ] || die "bundle metadata has no GATEWAY and elb_mode is '$mode'"
    namespace="$(sed -n 's/^NAMESPACE=//p' "$BUNDLE_DIR/meta.env")"
    log "elb_mode = ingress: waiting for the Ingress to report its VIP"
    gateway="$(
      "${SSH_BIN[@]}" "${SSH_OPTS[@]}" "${SSH_TARGET[@]}" "
        export KUBECONFIG='$REMOTE_DIR/kubeconfig'
        for i in \$(seq 1 60); do
          v=\$(kubectl -n '$namespace' get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
          if [ -n \"\$v\" ]; then echo \"\$v\"; exit 0; fi
          sleep 5
        done
        exit 1"
    )" || die "the Ingress has no VIP after 5 minutes; check 'kubectl -n $namespace describe ingress'"
    cert="$(sed -n 's/^CERT_ID=//p' "$BUNDLE_DIR/meta.env")"
    if [ -n "$cert" ]; then gateway="https://$gateway"; else gateway="http://$gateway"; fi
  fi
  printf '%s' "$gateway"
}


ensure_remote_bundle() {
  # `deploy-app` on its own used to jump straight to helm and fail with
  # "install.sh: No such file or directory" when nothing had been uploaded yet.
  # Produce and upload the bundle on demand instead.
  # Always re-render: values are derived from terraform outputs and the render
  # script, so a cached bundle silently deploys yesterday's configuration.
  cmd_bundle
  # Always upload: a bundle that merely exists can still be stale, and a stale
  # values.yaml silently deploys the previous configuration (this cost us a
  # debugging round on an ELB annotation that kept its old subnet id).
  log "uploading bundle to ${REMOTE_HOST}"
  cmd_push
}

cmd_exec() {
  [ "$#" -gt 0 ] || die "usage: remote-deploy.sh exec <command...>"
  setup_ssh
  # KUBECONFIG points at the bundle, so day-2 kubectl/helm work with no setup.
  "${SSH_BIN[@]}" "${SSH_OPTS[@]}" "${SSH_TARGET[@]}" \
    "export KUBECONFIG='$REMOTE_DIR/kubeconfig'; $*"
}

cmd_put() {
  [ -n "${1:-}" ] || die "usage: remote-deploy.sh put <local>:<remote>"
  setup_ssh
  local src="${1%%:*}" dst="${1#*:}"
  [ -f "$src" ] || die "local file not found: $src"
  log "uploading $src -> ${REMOTE_HOST}:${dst}"
  tar czf - -C "$(dirname "$src")" "$(basename "$src")" |
    "${SSH_BIN[@]}" "${SSH_OPTS[@]}" "${SSH_TARGET[@]}" \
      "d=\$(dirname '$dst'); mkdir -p \"\$d\" && tar xzf - -C \"\$d\" && echo uploaded"
}

case "${1:-all}" in
  bundle) cmd_bundle ;;
  push) cmd_push ;;
  deploy-app | verify)
    setup_ssh
    ensure_remote_bundle
    cmd_run "$1"
    ;;
  exec)
    shift
    cmd_exec "$@"
    ;;
  put)
    shift
    cmd_put "$@"
    ;;
  all)
    cmd_bundle
    cmd_push
    cmd_run deploy-app
    cmd_run verify
    ;;
  *)
    die "usage: remote-deploy.sh [bundle|push|deploy-app|verify|all|exec <cmd>|put <local>:<remote>]"
    ;;
esac
