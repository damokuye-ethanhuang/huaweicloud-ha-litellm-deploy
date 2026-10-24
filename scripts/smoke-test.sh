#!/usr/bin/env bash
# Probe the gateway: liveness, readiness, model list, and optionally a chat call.
#
#   ./scripts/smoke-test.sh [gateway-url]
#
# Environment:
#   LITELLM_MASTER_KEY  admin key (falls back to `terraform output`)
#   MODEL               model name for the chat test (optional)
#   INSECURE=1          skip TLS verification (self-signed certificates)
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPO_ROOT="$(repo_root)"
TF_DIR="${TF_DIR:-$REPO_ROOT/terraform/examples/cce-ha}"
URL="${1:-}"

require curl jq

if [ -z "$URL" ]; then
  URL="$(terraform_output "$TF_DIR" gateway_url)"
fi

CURL_OPTS=(-fsS --max-time 15)
[ "${INSECURE:-0}" = "1" ] && CURL_OPTS+=(-k)

if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  LITELLM_MASTER_KEY="$(terraform_output_json "$TF_DIR" app_env | jq -r '.LITELLM_MASTER_KEY')"
fi

log "liveness: $URL/health/liveliness"
curl "${CURL_OPTS[@]}" "$URL/health/liveliness" | jq -e . >/dev/null || die "liveness probe failed"

log "readiness: $URL/health/readiness"
readiness="$(curl "${CURL_OPTS[@]}" "$URL/health/readiness")"
printf '%s\n' "$readiness" | jq -e '.status == "healthy"' >/dev/null || die "readiness probe failed: $readiness"

log "models: $URL/v1/models"
curl "${CURL_OPTS[@]}" -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$URL/v1/models" | jq -r '.data[].id' | sed 's/^/  - /'

if [ -n "${MODEL:-}" ]; then
  log "chat completion: $MODEL"
  curl "${CURL_OPTS[@]}" "$URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg model "$MODEL" '{model: $model, messages: [{role: "user", content: "ping"}], max_tokens: 8}')" |
    jq -e '.choices[0].message' >/dev/null || die "chat completion failed"
fi

ok "smoke test passed"
