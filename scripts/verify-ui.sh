#!/usr/bin/env bash
# Prove the gateway works the way an operator sees it, from outside the VPC.
#
# The cluster API, the pods and the ELB VIP are all private: a browser on the
# operator laptop cannot reach them, so "it is deployed" is an unverifiable
# claim. This script closes that gap the same way the operator would:
#
#   1. fetch /ui/ HTML through the bastion and keep it as an artifact
#   2. open an ssh tunnel through the bastion and screenshot the rendered page
#   3. call readiness and /v1/models with the master key for machine evidence
#
# Artifacts land in out/verification/ (gitignored): the HTML proves the app is
# served, the PNG proves the SPA actually renders rather than returning a shell.
#
# Usage:
#   ./scripts/verify-ui.sh                     # html + screenshot + api checks
#   ./scripts/verify-ui.sh --no-screenshot     # server without a browser
#   ./scripts/verify-ui.sh --out /tmp/proof    # custom artifact directory
#   ./scripts/verify-ui.sh --path /docs        # any path on the gateway
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REPO="$(repo_root)"
TF_DIR="$REPO/terraform/examples/cce-ha"
OUT_DIR="$REPO/out/verification"
UI_PATH="/ui/"
SCREENSHOT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-screenshot) SCREENSHOT=0 ;;
    --out) OUT_DIR="${2:?--out needs a directory}"; shift ;;
    --path) UI_PATH="${2:?--path needs a value}"; shift ;;
    -*) die "unknown flag: $1" ;;
    *) die "unexpected argument: $1" ;;
  esac
  shift
done

remote() { "$REPO/scripts/remote-deploy.sh" exec "$@"; }

bastion_host() {
  if [ -n "${BASTION_HOST:-}" ]; then echo "$BASTION_HOST"; return; fi
  terraform_output_json "$TF_DIR" bastion | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_ip"])'
}

main() {
  require terraform
  mkdir -p "$OUT_DIR"

  local vip host slug scheme cert
  vip="$(remote "kubectl -n litellm get ingress litellm -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" 2>/dev/null || true)"
  [ -n "$vip" ] || die "the Ingress reports no VIP; run ./scripts/deploy.sh ingress first"
  cert="$(terraform_output "$TF_DIR" certificate_id 2>/dev/null || true)"
  scheme=http
  [ -n "$cert" ] && scheme=https
  host="$(bastion_host)"
  [ -n "$host" ] || die "cannot resolve the bastion IP (set BASTION_HOST)"
  slug="$(printf '%s' "${UI_PATH#/}" | tr '/' '-' | sed 's/-$//')"
  [ -n "$slug" ] || slug="root"

  log "gateway: $scheme://$vip$UI_PATH via bastion $host"

  # 1. the HTML itself, plus the status code that produced it
  local code bytes
  code="$(remote "curl -s -o /tmp/verify-ui.html -m 20 -w '%{http_code}' '$scheme://$vip$UI_PATH'")"
  [ "$code" = "200" ] || die "$UI_PATH returned HTTP $code through the VIP (expected 200)"
  remote "cat /tmp/verify-ui.html" >"$OUT_DIR/litellm-$slug.html"
  bytes="$(wc -c <"$OUT_DIR/litellm-$slug.html" | tr -d ' ')"
  ok "HTML: $OUT_DIR/litellm-$slug.html ($bytes bytes, HTTP $code)"
  local title
  title="$(python3 - "$OUT_DIR/litellm-$slug.html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"<title>(.*?)</title>", html, re.I | re.S)
print(m.group(1).strip() if m else "(no title)")
PY
)"
  log "title: $title"

  # 2. the rendered page - an SPA shell is not proof, a screenshot is
  if [ "$SCREENSHOT" = "1" ]; then
    local chrome
    chrome="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
    if [ -z "$chrome" ]; then
      warn "no chrome/chromium on this host: skipping the screenshot (HTML artifact still written)"
    else
      local port=18080 png="$OUT_DIR/litellm-$slug.png" key="${BASTION_KEY:-}"
      [ -n "$key" ] || die "BASTION_KEY is required for the screenshot tunnel"
      log "opening tunnel 127.0.0.1:$port -> $vip:$([ "$scheme" = https ] && echo 443 || echo 80)"
      ssh -i "$key" -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -o BatchMode=yes \
        -N -L "$port:$vip:$([ "$scheme" = https ] && echo 443 || echo 80)" "root@$host" &
      local tunnel=$!
      trap 'kill "$tunnel" 2>/dev/null || true' RETURN
      for _ in $(seq 1 15); do
        curl -s -o /dev/null -m 3 "http://127.0.0.1:$port$UI_PATH" && break
        sleep 1
      done
      "$chrome" --headless=new --no-sandbox --disable-gpu --no-proxy-server \
        --disable-dev-shm-usage --user-data-dir="$(mktemp -d)" --hide-scrollbars \
        --window-size=1560,980 --virtual-time-budget=8000 \
        --screenshot="$png" "http://127.0.0.1:$port$UI_PATH" >/dev/null 2>&1 || true
      kill "$tunnel" 2>/dev/null || true
      if [ -s "$png" ]; then
        ok "screenshot: $png ($(wc -c <"$png" | tr -d ' ') bytes)"
      else
        warn "screenshot failed; the HTML artifact is unaffected"
      fi
    fi
  fi

  # 3. machine evidence from the same path
  log "readiness:"
  remote "curl -sf -m 15 '$scheme://$vip/health/readiness'"
  echo
  log "models (master key from the bundle):"
  remote "set -a; . /root/litellm-bundle/app.env; set +a; curl -sf -m 15 -H \"Authorization: Bearer \$LITELLM_MASTER_KEY\" '$scheme://$vip/v1/models'" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join("  - "+m["id"] for m in d.get("data",[])))'
  ok "UI verification complete: $OUT_DIR"
}

main "$@"
