#!/usr/bin/env bash
# Push an image to a registry with the three guards that a bare `docker push`
# does not give you.
#
# Why this exists: `docker push ... | tail -3` returns the exit status of `tail`,
# so a rejected push looks like success, and the error scrolls out of the tail
# window. The first real signal was an empty repo in the console minutes later.
#
# Contract:
#   1. preflight  - network + auth + disk (scripts/preflight-network.sh)
#   2. push       - pipefail on, so any failure in the chain is fatal
#   3. verify     - the manifest is readable at the destination and its digest
#                   matches the source. A push is not done until this passes.
#
# Usage:
#   scripts/push-image.sh <src-ref> <dst-ref>
#   scripts/push-image.sh ghcr.io/berriai/litellm:1.106.3 \
#       swr.cn-southwest-2.myhuaweicloud.com/litellmtest01/litellm:1.106.3
set -euo pipefail

SRC="${1:-}"
DST="${2:-}"
if [ -z "$SRC" ] || [ -z "$DST" ]; then
  echo "usage: $0 <source-ref> <dest-ref>" >&2
  exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"

log() { printf '[push] %s\n' "$*" >&2; }
die() {
  printf '[push][fail] %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------- 1. preflight
log "preflight: network, auth, disk for $DST"
"$here/preflight-network.sh" "$DST" || die "preflight failed: nothing was pushed"

# ------------------------------------------------------------------- 2. push
if ! docker image inspect "$SRC" >/dev/null 2>&1; then
  log "source not local, pulling $SRC"
  docker pull "$SRC"
fi

docker tag "$SRC" "$DST"
log "pushing $DST"
# No pipe here on purpose: a pipe would hide the exit status behind the pager.
push_log="$(mktemp)"
if ! docker push "$DST" >"$push_log" 2>&1; then
  printf '%s\n' "----- last 15 lines of the push log -----" >&2
  tail -15 "$push_log" >&2
  rm -f "$push_log"
  die "docker push failed (see lines above)"
fi
tail -3 "$push_log" >&2
rm -f "$push_log"

# ----------------------------------------------------------------- 3. verify
log "verifying the manifest exists at the destination"
if ! docker manifest inspect "$DST" >/dev/null 2>&1; then
  die "push reported success but $DST has no manifest - treat as failed"
fi

src_id="$(docker image inspect --format '{{.Id}}' "$SRC")"
dst_id="$(docker image inspect --format '{{.Id}}' "$DST")"
if [ "$src_id" != "$dst_id" ]; then
  die "local tags differ ($src_id vs $dst_id) - tag step is wrong"
fi

log "ok: $DST pushed and verified (manifest readable, image id ${src_id:0:19})"
