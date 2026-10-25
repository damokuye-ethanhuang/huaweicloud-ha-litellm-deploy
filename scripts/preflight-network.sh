#!/usr/bin/env bash
# Preflight before ANY push or bulk transfer: network, then authentication.
#
# Rationale: pushes fail late and confusingly. A wrong password, a registry
# that resolves to the public endpoint instead of the internal one, or a full
# disk all surface only after several hundred MB have been streamed. This script
# fails in seconds with the specific cause.
#
# Run it on the host doing the push (the bastion), not on the operator PC:
#   ./scripts/preflight-network.sh swr.cn-southwest-2.myhuaweicloud.com/litellmtest01/litellm:1.106.3
#
# Checks, in order (stop at the first failure):
#   1 DNS      - the registry resolves, and to the internal 100.125.x service
#                address in pure-intranet setups
#   2 TCP      - port 443 accepts a connection
#   3 registry - /v2/ answers with a registry code (401/200), not a timeout
#   4 auth     - the image manifest is readable with the current credentials
#   5 disk     - enough free space for the layers
set -euo pipefail

IMAGE="${1:-}"
REGISTRY="${IMAGE%%/*}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"

fail=0
ok() { printf '[ ok ] %s\n' "$*"; }
bad() {
  printf '[fail] %s\n' "$*" >&2
  fail=1
}

[ -n "$IMAGE" ] || {
  echo "usage: $0 <registry>/<org>/<repo>:<tag>" >&2
  exit 2
}

echo "=== 1. DNS ==="
if getent hosts "$REGISTRY" >/dev/null 2>&1; then
  addr="$(getent hosts "$REGISTRY" | awk 'NR==1{print $1}')"
  case "$addr" in
    100.125.*) ok "$REGISTRY -> $addr (internal service network)" ;;
    *) ok "$REGISTRY -> $addr (public endpoint: needs internet egress)" ;;
  esac
else
  bad "$REGISTRY does not resolve (check VPC DNS / UDP 53 egress)"
fi

echo "=== 2. TCP 443 ==="
if [ "$fail" -eq 0 ]; then
  if nc -z -w 5 "$REGISTRY" 443 2>/dev/null; then
    ok "443 reachable"
  else
    bad "cannot open $REGISTRY:443 (security group egress, or no route)"
  fi
fi

echo "=== 3. registry handshake ==="
if [ "$fail" -eq 0 ]; then
  code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$REGISTRY/v2/" || echo 000)"
  case "$code" in
    200 | 401) ok "/v2/ answered $code" ;;
    *) bad "/v2/ answered $code (expected 200 or 401)" ;;
  esac
fi

echo "=== 4. authentication ==="
if [ "$fail" -eq 0 ]; then
  if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
    ok "credentials can read $IMAGE"
  else
    bad "cannot read $IMAGE: not logged in, wrong password, or repo does not exist"
  fi
fi

echo "=== 5. disk ==="
if [ "$fail" -eq 0 ]; then
  # /var/lib/docker, falling back to / when docker uses a different root.
  target="/var/lib/docker"
  [ -d "$target" ] || target="/"
  free_gb="$(df -BG --output=avail "$target" 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [ "${free_gb:-0}" -ge "$MIN_FREE_GB" ]; then
    ok "$free_gb GiB free on $target"
  else
    bad "only ${free_gb:-0} GiB free on $target (need >= $MIN_FREE_GB)"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "preflight failed: fix the above before pushing anything" >&2
  exit 1
fi
echo "preflight passed: safe to push"
