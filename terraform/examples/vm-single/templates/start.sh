#!/bin/bash
# Idempotent bootstrap for the single-node LiteLLM lab stack.
set -euo pipefail

ENV_FILE=/opt/litellm/litellm.env
CONFIG_FILE=/opt/litellm/config.yaml

set -a
# shellcheck disable=SC1090  # path and contents are provided by cloud-init
. "$ENV_FILE"
set +a

docker network inspect litellm >/dev/null 2>&1 || docker network create litellm

if ! docker ps -a --format '{{.Names}}' | grep -qx litellm-pg; then
  mkdir -p /opt/litellm/pgdata
  docker run -d --name litellm-pg --restart always --network litellm \
    -e POSTGRES_DB=litellm \
    -e POSTGRES_USER=litellm \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -v /opt/litellm/pgdata:/var/lib/postgresql/data \
    postgres:16
fi

if ! docker ps -a --format '{{.Names}}' | grep -qx litellm-redis; then
  docker run -d --name litellm-redis --restart always --network litellm \
    redis:7 redis-server --requirepass "$REDIS_PASSWORD" --appendonly yes
fi

for _ in $(seq 1 60); do
  if docker exec litellm-pg pg_isready -U litellm >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

docker rm -f litellm >/dev/null 2>&1 || true
docker run -d --name litellm --restart always --network litellm \
  -p 4000:4000 \
  -v "$CONFIG_FILE":/app/config/config.yaml:ro \
  --env-file "$ENV_FILE" \
  "$LITELLM_IMAGE" --config /app/config/config.yaml --port 4000
