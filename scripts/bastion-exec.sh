#!/usr/bin/env bash
# Run a command on the operator bastion over SSH, from wherever the agent runs.
#
#   ./scripts/bastion-exec.sh <command...>
#   ./scripts/bastion-exec.sh --put <local>:<remote>
#   ./scripts/bastion-exec.sh --kubeconfig
#
# Why this exists: the CCE cluster API has no public endpoint. The bastion is
# the only host with a public EIP, so helm/kubectl are executed there and the
# agent's own machine is nothing but an SSH client.
#
# Environment:
#   BASTION_HOST      public EIP           (default: terraform output bastion.public_ip)
#   BASTION_USER      ssh user             (default: root)
#   BASTION_KEY       private key path     (preferred; otherwise the password from CSMS)
#   BASTION_PASSWORD  password             (only when no key is available)
#   KUBECONFIG_FILE   local kubeconfig path (default: ~/.kube/litellm-gateway.yaml)
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPO="$(repo_root)"
TF_DIR="${TF_DIR:-$REPO/terraform/examples/cce-ha}"
BASTION_USER="${BASTION_USER:-root}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-$HOME/.kube/litellm-gateway.yaml}"

[ -d "$TF_DIR" ] || die "terraform directory not found: $TF_DIR"

if [ -z "${BASTION_HOST:-}" ]; then
  BASTION_HOST="$(terraform -chdir="$TF_DIR" output -json bastion 2>/dev/null | jq -r '.public_ip // empty')"
fi
[ -n "${BASTION_HOST:-}" ] || die "BASTION_HOST is empty: the bastion is not deployed (bastion_enabled = false?)"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30)

build_ssh() {
  if [ -n "${BASTION_KEY:-}" ]; then
    [ -f "$BASTION_KEY" ] || die "BASTION_KEY does not exist: $BASTION_KEY"
    SSH=(ssh "${SSH_OPTS[@]}" -i "$BASTION_KEY" "${BASTION_USER}@${BASTION_HOST}")
    SCP=(scp "${SSH_OPTS[@]}" -i "$BASTION_KEY")
  elif [ -n "${BASTION_PASSWORD:-}" ]; then
    command -v sshpass >/dev/null 2>&1 || die "sshpass is required when using BASTION_PASSWORD"
    SSH=(sshpass -p "$BASTION_PASSWORD" ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_HOST}")
    SCP=(sshpass -p "$BASTION_PASSWORD" scp "${SSH_OPTS[@]}")
  else
    die "set BASTION_KEY (recommended) or BASTION_PASSWORD"
  fi
}

case "${1:-}" in
  --kubeconfig)
    # Push the cluster kubeconfig so helm can run on the bastion.
    build_ssh
    [ -f "$KUBECONFIG_FILE" ] || die "local kubeconfig missing: $KUBECONFIG_FILE (run scripts/deploy.sh deploy-app first)"
    log "uploading kubeconfig to ${BASTION_HOST}:/root/.kube/config"
    "${SCP[@]}" "$KUBECONFIG_FILE" "${BASTION_USER}@${BASTION_HOST}:/root/.kube/config.new"
    "${SSH[@]}" 'mkdir -p /root/.kube && mv /root/.kube/config.new /root/.kube/config && chmod 600 /root/.kube/config && kubectl version --client >/dev/null 2>&1 && echo "bastion kubeconfig ready"'
    ;;
  --put)
    shift
    [ -n "${1:-}" ] || die "usage: --put <local>:<remote>"
    build_ssh
    "${SCP[@]}" "${1%%:*}" "${BASTION_USER}@${BASTION_HOST}:${1#*:}"
    ;;
  "")
    die "usage: bastion-exec.sh <command...> | --put <local>:<remote> | --kubeconfig"
    ;;
  *)
    build_ssh
    # kubeconfig must already be on the bastion (--kubeconfig)
    "${SSH[@]}" "export KUBECONFIG=/root/.kube/config; $*"
    ;;
esac
