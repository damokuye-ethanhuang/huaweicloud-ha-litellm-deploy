#!/usr/bin/env bash
# Converge the CCE ELB Ingress, exactly once, with the parameters that work.
#
# Why this exists as its own stage instead of a plain `helm upgrade`:
#   1. kubernetes.io/elb.autocreate is IMMUTABLE. Any change to the subnet,
#      zone list, port or flavor is rejected by the API and the OLD ELB keeps
#      serving - the release looks healthy while the ingress is stale. The only
#      way through is delete-and-recreate, which this script automates.
#   2. The two subnet fields take DIFFERENT id types, and swapping them fails
#      with a 404 that names neither field:
#         vip_subnet_cidr_id -> Neutron subnet id
#         elb_virsubnet_ids  -> VPC network id
#      Both belong to the access subnet; the VIP sits in front of the app subnet.
#   3. The listener port has to match the protocol (80 without a certificate,
#      443 with one) and the Service must be NodePort, otherwise the ELB pool
#      has no members: the VIP accepts and then hangs up.
#
# Everything is read from the rendered bundle, so the script converges to what
# deploy-app would have deployed - it never invents a second source of truth.
#
# Usage:
#   ./scripts/deploy.sh ingress              # converge, then prove it serves
#   ./scripts/ingress-apply.sh --check       # report drift, change nothing
#   BASTION_KEY=... ./scripts/ingress-apply.sh
#
# Exit codes: 0 converged and serving, 1 converge failed, 2 drift found (--check).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPO="$(repo_root)"
TF_DIR="$REPO/terraform/examples/cce-ha"
BUNDLE_DIR="${BUNDLE_DIR:-$OUT_DIR/bastion}"
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

remote() { "$REPO/scripts/remote-deploy.sh" exec "$@"; }

main() {
  require terraform
  require python3

  local mode vip
  mode="$(terraform_output "$TF_DIR" elb_mode)"
  if [ "$mode" != "ingress" ]; then
    die "elb_mode is '$mode': the ELB is owned by Terraform (module.elb), not by an Ingress. Nothing to converge; run deploy-app."
  fi

  [ -f "$BUNDLE_DIR/values.yaml" ] || die "no rendered bundle at $BUNDLE_DIR; run ./scripts/deploy.sh deploy-app (or --remote deploy-app) first"

  # Desired state comes from the bundle, i.e. from the same renderer helm uses.
  local port autocreate
  read -r port autocreate < <(python3 - "$BUNDLE_DIR/values.yaml" <<'PY'
import sys, yaml, json
v = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
a = ((v.get("ingress") or {}).get("annotations") or {})
port = str(a.get("kubernetes.io/elb.port", ""))
auto = a.get("kubernetes.io/elb.autocreate", "")
if isinstance(auto, dict):
    auto = json.dumps(auto, separators=(",", ":"))
print(port, auto)
PY
)
  if [ -z "$port" ] || [ -z "$autocreate" ]; then
    die "bundle has no elb.port / elb.autocreate annotation; re-run deploy-app to re-render values"
  fi

  # Sanity check the id types before touching the cluster: this is the failure
  # that costs ten minutes because it only shows up as ELB.8904 in events.
  python3 - "$autocreate" <<'PY'
import json, sys, re
spec = json.loads(sys.argv[1])
vir = spec.get("elb_virsubnet_ids") or []
vip = spec.get("vip_subnet_cidr_id") or ""
if not vir or not vip:
    sys.exit("elb.autocreate is missing elb_virsubnet_ids or vip_subnet_cidr_id")
for x in vir + [vip]:
    if not re.fullmatch(r"[0-9a-f-]{36}", x):
        sys.exit(f"'{x}' is not a uuid; check the terraform output ingress_elb")
print(f"  zone(s): {', '.join(spec.get('available_zone', []))}")
print(f"  vip subnet: {vip}")
print(f"  elb subnets: {', '.join(vir)}")
PY

  local live
  if ! live="$(remote "kubectl -n litellm get ingress litellm -o jsonpath='{.metadata.annotations.kubernetes\.io/elb\.autocreate}|{.metadata.annotations.kubernetes\.io/elb\.port}'" 2>&1)"; then
    # "not found" is a valid starting point; anything else (ssh, kubectl auth)
    # is a failure and must not be mistaken for an empty cluster.
    case "$live" in
      *NotFound* | *"not found"*) live="" ;;
      *) die "cannot read the ingress from the cluster: $live" ;;
    esac
  fi

  if [ "$live" = "$autocreate|$port" ]; then
    ok "ingress annotations already match the bundle (port $port)"
    [ "$CHECK_ONLY" = "1" ] && return 0
    verify_serving
    return 0
  fi

  if [ -z "$live" ]; then
    log "no ingress in the cluster yet"
  else
    warn "ingress annotations differ from the bundle:"
    log "  cluster: ${live:0:120}..."
    log "  bundle : ${autocreate:0:120}..."
  fi

  if [ "$CHECK_ONLY" = "1" ]; then
    warn "drift detected (--check): re-run without --check to converge"
    exit 2
  fi

  # autocreate is immutable: delete first, otherwise helm's patch is rejected
  # and the old ELB silently keeps serving.
  log "deleting the immutable ingress so it can be recreated with the new spec"
  remote "kubectl -n litellm delete ingress litellm --ignore-not-found --wait=true" || true

  log "re-applying the release (helm upgrade recreates the ingress)"
  "$REPO/scripts/remote-deploy.sh" deploy-app

  log "waiting for the Ingress to report its VIP"
  vip=""
  for _ in $(seq 1 60); do
    vip="$(remote "kubectl -n litellm get ingress litellm -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" 2>/dev/null || true)"
    [ -n "$vip" ] && break
    sleep 5
  done
  [ -n "$vip" ] || die "the Ingress still has no VIP after 5 minutes; check 'kubectl -n litellm describe ingress litellm' for ELB.xxxx events"

  ok "ingress converged: VIP $vip (port $port)"
  verify_serving
}

verify_serving() {
  # Proof that listener, pool members and backend all line up: a readiness
  # probe through the VIP from inside the VPC. An empty pool shows up here as a
  # timeout, which is why this is the acceptance test and not a pod check.
  local vip scheme
  vip="$(remote "kubectl -n litellm get ingress litellm -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" 2>/dev/null || true)"
  [ -n "$vip" ] || die "no VIP on the ingress"
  scheme=http
  [ -n "$(terraform_output "$TF_DIR" certificate_id 2>/dev/null || true)" ] && scheme=https

  log "readiness through the VIP: $scheme://$vip/health/readiness"
  remote "curl -sf -m 15 '$scheme://$vip/health/readiness'" >/dev/null \
    || die "readiness failed through $vip: the ELB listener is up but no backend answered. Check that the Service is NodePort and the pool has members (docs/troubleshooting.md)."
  ok "serving through $vip"
  echo "$vip"
}

main "$@"
