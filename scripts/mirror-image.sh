#!/usr/bin/env bash
# Mirror the LiteLLM image into Huawei Cloud SWR.
#
# China-region clusters often cannot pull ghcr.io directly. Mirror once per
# region, then point litellm_image_repository at the SWR path.
#
#   SWR_REGION=cn-north-4 SWR_ORG=my-org ./scripts/mirror-image.sh [version]
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

VERSION="${1:-1.106.3}"
SRC_REPO="${SRC_REPO:-ghcr.io/berriai/litellm}"
SWR_REGION="${SWR_REGION:?set SWR_REGION, for example cn-north-4}"
SWR_ORG="${SWR_ORG:?set SWR_ORG (the SWR organization namespace)}"

require docker

if [ -z "${HW_ACCESS_KEY:-}" ] || [ -z "${HW_SECRET_KEY:-}" ]; then
  die "HW_ACCESS_KEY / HW_SECRET_KEY are required to authenticate against SWR"
fi

REGISTRY="swr.${SWR_REGION}.myhuaweicloud.com"
DEST="${REGISTRY}/${SWR_ORG}/litellm:${VERSION}"

log "docker login $REGISTRY"
printf '%s' "$HW_SECRET_KEY" | docker login "$REGISTRY" \
  --username "${SWR_REGION}@${HW_ACCESS_KEY}" \
  --password-stdin

log "pull $SRC_REPO:$VERSION"
docker pull "${SRC_REPO}:${VERSION}"

log "tag $DEST"
docker tag "${SRC_REPO}:${VERSION}" "$DEST"

log "push $DEST"
docker push "$DEST"

ok "mirrored - set litellm_image_repository = \"${REGISTRY}/${SWR_ORG}/litellm\" and litellm_version = \"${VERSION}\""
