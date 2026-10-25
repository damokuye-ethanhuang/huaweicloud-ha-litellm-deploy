#!/usr/bin/env bash
# Stage-driven deployment entry point.
#
#   ./scripts/deploy.sh                 # preflight -> plan (stops before apply)
#   ./scripts/deploy.sh preflight
#   ./scripts/deploy.sh plan
#   ./scripts/deploy.sh apply-infra
#   ./scripts/deploy.sh deploy-app
#   ./scripts/deploy.sh verify
#   ./scripts/deploy.sh all             # everything, apply included
#
# Remote execution (laptop outside the VPC: the cluster API and the ELB VIP are
# both unreachable, only the bastion is):
#
#   ./scripts/deploy.sh --remote deploy-app   # bundle + upload + helm on the bastion
#   ./scripts/deploy.sh --remote verify       # smoke test on the bastion
#   ./scripts/deploy.sh --remote all          # bundle + upload + deploy-app + verify
#
# Every stage is idempotent and can be re-run on its own after a failure.
# All parameters come from deploy-inputs.yaml via preflight; nothing is typed
# twice. Secrets never pass through this script's arguments.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPO="$(repo_root)"
load_credentials
TF_DIR="$REPO/terraform/examples/cce-ha"
OUT_DIR="$REPO/out"
REMOTE=0
STAGE=""
for arg in "$@"; do
  case "$arg" in
    --remote) REMOTE=1 ;;
    -*) die "unknown flag: $arg" ;;
    *) STAGE="$arg" ;;
  esac
done
STAGE="${STAGE:-plan}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/litellm-gateway.yaml}"
export KUBECONFIG="$KUBECONFIG_FILE"

resolve_cce_version() {
  # CCE retires versions and wants an exact patch; resolve it per run instead of
  # pinning a value that goes stale. Skipped silently without credentials.
  local py=""
  for candidate in "$REPO/.venv-sdk/bin/python" python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import huaweicloudsdkcce' >/dev/null 2>&1; then
      py="$candidate"
      break
    fi
  done
  [ -n "$py" ] || return 0
  if [ -z "${HW_ACCESS_KEY:-}" ] && [ ! -f "$REPO/secrets/hw.env" ] && [ ! -f "$HOME/.huaweicloud/credentials" ]; then
    return 0
  fi
  log "resolving the CCE version currently supported in this region"
  "$py" "$REPO/scripts/resolve-cce-version.py" || warn "could not resolve the CCE version; keeping the current value"
}

resolve_az() {
  # az_policy=auto: ask the region which AZs are live and which of them offer the
  # node flavor, then rewrite az_list. Only the resolved list reaches Terraform,
  # because huaweicloud_availability_zones has no filter argument to express a
  # preference. az_policy=fixed keeps az_list untouched.
  local py=""
  for candidate in "$REPO/.venv-sdk/bin/python" python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      py="$candidate"
      break
    fi
  done
  [ -n "$py" ] || return 0
  if [ -z "${HW_ACCESS_KEY:-}" ] && [ ! -f "$REPO/secrets/hw.env" ] && [ ! -f "$HOME/.huaweicloud/credentials" ]; then
    return 0
  fi
  log "resolving availability zones (az_policy from deploy-inputs.yaml)"
  "$py" "$REPO/scripts/resolve-az.py" || warn "could not resolve AZs; keeping the current az_list"
}

run_preflight() {
  resolve_cce_version
  resolve_az
  log "preflight: validating deploy-inputs.yaml"
  python3 "$REPO/scripts/preflight.py" || die "preflight blocked - fix deploy-inputs.yaml and rerun"
  ok "preflight passed; artifacts rendered into out/"
}

run_plan() {
  require terraform
  run_preflight
  log "terraform init"
  terraform -chdir="$TF_DIR" init -input=false -upgrade >/dev/null
  log "terraform plan (saved to tfplan)"
  terraform -chdir="$TF_DIR" plan -input=false -out=tfplan
  ok "plan saved: $TF_DIR/tfplan - review it, then run: ./scripts/deploy.sh apply-infra"
}

run_apply() {
  require terraform
  [ -f "$TF_DIR/tfplan" ] || die "no saved plan; run './scripts/deploy.sh plan' first (never apply without reviewing a plan)"
  log "terraform apply"
  terraform -chdir="$TF_DIR" apply -input=false tfplan
  rm -f "$TF_DIR/tfplan"
  ok "infrastructure ready"
}

run_app() {
  require helm kubectl jq terraform
  log "kubeconfig -> $KUBECONFIG_FILE"
  mkdir -p "$(dirname "$KUBECONFIG_FILE")"
  terraform -chdir="$TF_DIR" output -raw kube_config_raw >"$KUBECONFIG_FILE"
  chmod 600 "$KUBECONFIG_FILE"

  ELB_MODE="$(terraform_output "$TF_DIR" elb_mode)"
  ELB_ID="$(terraform_output "$TF_DIR" loadbalancer_id)"
  CERT_ID="$(terraform_output "$TF_DIR" certificate_id)"
  INGRESS_ELB_JSON="$(terraform_output_json "$TF_DIR" ingress_elb)"
  APP_ENV_JSON="$(terraform_output_json "$TF_DIR" app_env)"
  IMAGE="$(terraform_output "$TF_DIR" litellm_image)"

  NAMESPACE="${NAMESPACE:-litellm}"
  RELEASE="${RELEASE:-litellm}"

  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

  log "namespace secret (values from Terraform, provider keys from secrets/app.env if present)"
  secret_args=(
    --from-literal=DATABASE_URL="$(jq -r .DATABASE_URL <<<"$APP_ENV_JSON")"
    --from-literal=LITELLM_MASTER_KEY="$(jq -r .LITELLM_MASTER_KEY <<<"$APP_ENV_JSON")"
    --from-literal=LITELLM_SALT_KEY="$(jq -r .LITELLM_SALT_KEY <<<"$APP_ENV_JSON")"
    --from-literal=REDIS_HOST="$(jq -r .REDIS_HOST <<<"$APP_ENV_JSON")"
    --from-literal=REDIS_PORT="$(jq -r .REDIS_PORT <<<"$APP_ENV_JSON")"
    --from-literal=REDIS_PASSWORD="$(jq -r .REDIS_PASSWORD <<<"$APP_ENV_JSON")"
    --from-literal=REDIS_SSL="$(jq -r .REDIS_SSL <<<"$APP_ENV_JSON")"
  )
  if [ -f "$REPO/secrets/app.env" ]; then
    secret_args+=(--from-env-file="$REPO/secrets/app.env")
  else
    warn "secrets/app.env not found: model provider keys are not configured"
  fi
  kubectl -n "$NAMESPACE" create secret generic litellm-secrets \
    "${secret_args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # SWR pull secret (supply chain = swr): same 24h credential mirror-image.sh
  # uses; refreshed on every deploy-app so an expired secret never surfaces as
  # ImagePullBackOff days later.
  case "$IMAGE" in
    swr.*.myhuaweicloud.com/*)
      swr_region="${IMAGE#swr.}"; swr_region="${swr_region%%.*}"
      if creds="$(SWR_REGION="$swr_region" "$REPO/scripts/mirror-image.sh" --print-creds)"; then
        read -r swr_user swr_pass <<<"$creds"
        kubectl -n "$NAMESPACE" create secret docker-registry swr-cred \
          --docker-server="swr.${swr_region}.myhuaweicloud.com" \
          --docker-username="$swr_user" --docker-password="$swr_pass" \
          --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        log "swr pull secret refreshed (valid 24h)"
      else
        warn "SWR credential fetch failed; keeping the existing swr-cred secret"
      fi
      ;;
  esac

  # Nodes have no public egress. Deploying an upstream registry reference in
  # swr mode guarantees ImagePullBackOff, so fail here with the fix in hand.
  case "$IMAGE" in
    swr.*.myhuaweicloud.com/*) ;;
    ghcr.io/*|docker.io/*|ghcr.nju.edu.cn/*)
      die "image is '$IMAGE' but the supply chain is swr: run scripts/mirror-image.sh <tag> on the bastion first (terraform output litellm_image shows the expected reference)"
      ;;
  esac

  VALUES="$(mktemp)"
  trap 'rm -f "$VALUES"' EXIT
  python3 "$REPO/scripts/render-helm-values.py" \
    --src "$OUT_DIR/helm-values.yaml" \
    --dst "$VALUES" \
    --image "$IMAGE" \
    --mode "$ELB_MODE" \
    --elb-id "$ELB_ID" \
    --cert-id "$CERT_ID" \
    --ingress-json "$INGRESS_ELB_JSON"

  log "helm upgrade --install (migration job runs first as a pre-install hook)"
  helm upgrade --install "$RELEASE" "$REPO/charts/litellm" \
    --namespace "$NAMESPACE" \
    --values "$VALUES" \
    --set existingSecret=litellm-secrets \
    --wait --timeout "${HELM_TIMEOUT:-25m}"
  ok "gateway deployed"
}

run_verify() {
  require terraform kubectl curl jq
  ENDPOINT="$(terraform_output "$TF_DIR" gateway_url)"
  if [ -z "$ENDPOINT" ]; then
    # Ingress mode: the ELB - and therefore the VIP - only exists after the
    # Ingress controller has reconciled, so read it back from the Ingress status
    # instead of asking Terraform (which never created the ELB).
    NAMESPACE="${NAMESPACE:-litellm}"
    SCHEME="http"
    if [ -n "$(terraform_output "$TF_DIR" certificate_id)" ]; then SCHEME="https"; fi
    log "waiting for the Ingress to report its ELB VIP"
    VIP=""
    for _ in $(seq 1 60); do
      VIP="$(kubectl -n "$NAMESPACE" get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
      if [ -n "$VIP" ]; then break; fi
      sleep 5
    done
    [ -n "$VIP" ] || die "the Ingress has no VIP after 5 minutes; check 'kubectl -n $NAMESPACE describe ingress'"
    ENDPOINT="$SCHEME://$VIP"
  fi
  log "verifying $ENDPOINT"
  "$REPO/scripts/smoke-test.sh" "$ENDPOINT" || die "smoke test failed; see docs/troubleshooting.md"
  ok "verification passed"
}

run_bastion_key() {
  # Terraform owns the keypair. Write the private half somewhere the SSH/rsync
  # paths can use, 0600, inside .local (gitignored).
  local out="$REPO/.local/bastion_key"
  local key
  key="$(terraform_output "$TF_DIR" bastion_private_key 2>/dev/null || true)"
  if [ -z "$key" ]; then
    if [ -f "$out" ]; then
      log "no Terraform-generated key (operator supplied one); keeping $out"
      return 0
    fi
    die "bastion_private_key is empty: the operator supplied bastion_public_key, use their private key"
  fi
  mkdir -p "$(dirname "$out")"
  ( umask 077; printf '%s\n' "$key" >"$out" )
  chmod 600 "$out"
  # ssh(1) reads <key>.pub to decide which key to offer. A stale .pub makes it
  # offer a key the server never received, and every login fails as "Permission
  # denied (publickey)" while the private half is perfectly fine.
  ssh-keygen -y -f "$out" >"$out.pub" 2>/dev/null || rm -f "$out.pub"
  [ -f "$out.pub" ] && chmod 644 "$out.pub"
  ok "wrote $out"
  log "ssh -i $out root@$(terraform_output "$TF_DIR" bastion_public_ip 2>/dev/null || echo '<bastion-ip>')"
}

if [ "$REMOTE" = "1" ]; then
  # In-cluster stages cannot run here: hand the whole bundle to the bastion.
  case "$STAGE" in
    deploy-app | verify | all) exec "$REPO/scripts/remote-deploy.sh" "$STAGE" ;;
    *) die "--remote only applies to deploy-app, verify and all (got '$STAGE')" ;;
  esac
fi

case "$STAGE" in
  preflight) run_preflight ;;
  plan) run_plan ;;
  apply-infra) run_apply ;;
  deploy-app) run_app ;;
  verify) run_verify ;;
  bastion-key) run_bastion_key ;;
  all)
    run_plan
    run_apply
    run_app
    run_verify
    ;;
  *)
    die "unknown stage '$STAGE' (preflight|plan|apply-infra|deploy-app|verify|bastion-key|all)"
    ;;
esac
