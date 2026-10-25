#!/usr/bin/env bash
# Apply the infrastructure in dependency order instead of one flat batch.
#
# Why staged and not a single `terraform apply`:
#   1. Fail fast on the pieces that historically break. The ELB needs a neutron
#      subnet id, so a one-minute apply tells us whether that wiring is right
#      before we spend twenty minutes on a database.
#   2. Start the slow pieces as early as their dependencies allow. RDS primary/
#      standby takes 15-20 min, CCE nodes 10-15 min; nothing else can start
#      before the network and security groups exist, which stage 0 asserts.
#   3. Keep metered, fully independent resources (bastion EIP) for the end, so a
#      failed early stage does not leave a public IP billing.
#
# Stage order (each waits for the previous to finish):
#   1 edge      ELB + access log      fast, known-risky wiring, validates early
#   2 data      RDS instance+database longest lead time, needed by the app
#   3 compute   CCE worker nodes      slow, depends on cluster + subnets
#   4 cache     DCS Redis             in-place update, quick
#   5 ops       bastion + EIP         public IP, costs money, purely optional
#
# Usage:
#   scripts/apply-staged.sh                # all stages
#   scripts/apply-staged.sh edge data      # named stages only, in given order
#   DRY_RUN=1 scripts/apply-staged.sh      # plan each stage, apply nothing
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

readonly EXAMPLE_DIR="${EXAMPLE_DIR:-terraform/examples/cce-ha}"
# Absolute: terraform -chdir resolves relative paths against the example dir.
readonly PLAN_DIR="${PLAN_DIR:-$(repo_root)/.local/plans}"

# Resource addresses per stage. Keep dependencies inside a stage, never across
# two stages in the reverse direction: a stage must only reference things the
# previous stages already created.
stage_targets() {
  case "$1" in
    edge)
      # Load balancer and its access log. Backend pools are added by the CCE
      # ingress controller later, so no node dependency here.
      echo "module.elb huaweicloud_elb_log.this[0]"
      ;;
    data)
      echo "module.postgres"
      ;;
    compute)
      # Address needs the resource's own name: .workers is the cce_node resource.
      echo "module.cce.huaweicloud_cce_node.workers"
      ;;
    cache)
      echo "module.redis"
      ;;
    ops)
      # Bastion and its EIP association: the only public entry point.
      echo "module.bastion"
      ;;
    *)
      die "unknown stage: $1 (valid: edge data compute cache ops)"
      ;;
  esac
}

stage_title() {
  case "$1" in
    edge) echo "ELB + access log (fail-fast on the neutron-subnet wiring)" ;;
    data) echo "RDS PostgreSQL primary/standby + litellm database (slowest)" ;;
    compute) echo "CCE worker nodes x3, one per AZ" ;;
    cache) echo "DCS Redis primary/standby" ;;
    ops) echo "bastion host + EIP (metered, kept last on purpose)" ;;
  esac
}

run_stage() {
  local stage="$1"
  local -a targets=() args=()
  read -r -a targets <<<"$(stage_targets "$stage")"

  log "stage ${stage}: $(stage_title "$stage")"

  for t in "${targets[@]}"; do
    args+=(-target="$t")
  done

  if [ "${DRY_RUN:-0}" = "1" ]; then
    terraform -chdir="$EXAMPLE_DIR" plan -input=false -no-color "${args[@]}"
    return 0
  fi

  mkdir -p "$PLAN_DIR"
  local plan_file="${PLAN_DIR}/${stage}.tfplan"

  # Save then apply the exact plan that was reviewed, so what runs is what the
  # log shows - no re-planning drift between the two commands.
  terraform -chdir="$EXAMPLE_DIR" plan -input=false -no-color \
    -out="$plan_file" "${args[@]}"
  terraform -chdir="$EXAMPLE_DIR" apply -input=false -no-color "$plan_file"
  ok "stage ${stage} complete"
}

main() {
  cd "$(repo_root)"
  require terraform
  load_credentials
  if [ -z "${HW_ACCESS_KEY:-}" ] || [ -z "${HW_SECRET_KEY:-}" ]; then
    die "no credentials: run ./scripts/creds.sh set, or export HW_ACCESS_KEY/HW_SECRET_KEY"
  fi
  [ -d "$EXAMPLE_DIR" ] || die "example dir not found: $EXAMPLE_DIR"

  local -a stages=("$@")
  if [ "${#stages[@]}" -eq 0 ]; then
    stages=(edge data compute cache ops)
  fi

  local stage
  for stage in "${stages[@]}"; do
    run_stage "$stage"
  done

  ok "all requested stages applied"
}

main "$@"
