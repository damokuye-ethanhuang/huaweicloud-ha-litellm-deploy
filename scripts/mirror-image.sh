#!/usr/bin/env bash
# Copy the upstream LiteLLM image into SWR in the same region.
#
# Login caveat that cost us an hour: `docker login -u {region}@{AK} -p {SK}` is
# REJECTED by SWR ("denied: Authenticate Error"), and an imagePullSecret built
# from it fails in-cluster with "failed to fetch oauth token ... 401". The only
# credential SWR accepts is the temporary login command from
#   POST https://swr-api.<region>.myhuaweicloud.com/v2/manage/utils/secret
# which is valid for 24h. Enable "long-term login command" in the console for
# anything beyond a lab.
#
# Usage (run ON THE BASTION, the only host with public egress):
#   ./scripts/mirror-image.sh 1.106.3
# SWR_ORG defaults to deploy-inputs.yaml swr_org; SRC_REPO defaults to the
# fastest measured mirror (ghcr.nju.edu.cn, ~7 MB/s from cn-southwest-2).
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

VERSION="${1:-}"

# --print-creds: output "user password" for the SWR registry and exit. Used by
# remote-deploy.sh to build the in-cluster pull secret; the credential is the
# same 24h temporary login the mirror flow uses.
if [ "${1:-}" = "--print-creds" ]; then
  load_credentials
  if [ -z "${HW_ACCESS_KEY:-}" ] || [ -z "${HW_SECRET_KEY:-}" ]; then
    die "HW_ACCESS_KEY / HW_SECRET_KEY are required to obtain an SWR login token"
  fi
  REGION="${SWR_REGION:-cn-southwest-2}"
  creds="$(python3 - "$REGION" <<'PYCRED'
import base64, json, os, sys, urllib.request, urllib.error
from datetime import datetime, timezone

region, = sys.argv[1:]
ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()

auth = {"auth": {"identity": {"methods": ["hw_ak_sk"],
  "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}}},
  "scope": {"project": {"name": region}}}}
req = urllib.request.Request("https://iam.myhuaweicloud.com/v3/auth/tokens",
  data=json.dumps(auth).encode(), method="POST")
req.add_header("Content-Type", "application/json;charset=utf8")
req.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
with urllib.request.urlopen(req, timeout=25) as resp:
    token = resp.headers["X-Subject-Token"]

req = urllib.request.Request(
    f"https://swr-api.{region}.myhuaweicloud.com/v2/manage/utils/secret", method="POST")
req.add_header("X-Auth-Token", token)
try:
    with urllib.request.urlopen(req, timeout=25) as resp:
        body = json.load(resp)
except urllib.error.HTTPError as exc:
    sys.exit(f"SWR secret request failed: {exc.code} {exc.read()[:200].decode()}")
auths = body.get("auths") or {}
if not auths:
    sys.exit("SWR returned no auths - is the region/endpoint correct?")
blob = next(iter(auths.values()))["auth"]
print(base64.b64decode(blob).decode(), end="")
PYCRED
)"
  # creds is "user:password"; print space-separated for the caller.
  printf '%s %s\n' "${creds%%:*}" "${creds#*:}"
  exit 0
fi
[ -n "$VERSION" ] || die "usage: $0 <image-tag>"
SRC_REPO="${SRC_REPO:-ghcr.nju.edu.cn/berriai/litellm}"
SWR_REGION="${SWR_REGION:-$(
  sed -n 's/^ *region: *//p' "$(repo_root)/deploy-inputs.yaml" | head -1 | tr -d '"'
)}"
# swr_org lives in deploy-inputs.yaml; the YAML is nested, so read it with
# python instead of guessing at sed patterns.
SWR_ORG="${SWR_ORG:-$(python3 - <<'PYEOF'
import pathlib, yaml
d = yaml.safe_load(pathlib.Path("$(repo_root)/deploy-inputs.yaml").read_text(encoding="utf-8"))
for section in d.values():
    if isinstance(section, list):
        for item in section:
            if isinstance(item, dict) and item.get("key") == "swr_org":
                print(item.get("value") or "")
                raise SystemExit
PYEOF
)}"
[ -n "$SWR_ORG" ] || die "swr_org is empty: set it in deploy-inputs.yaml (image_supply section) or export SWR_ORG"
SWR_REGION="${SWR_REGION:-cn-southwest-2}"

load_credentials
if [ -z "${HW_ACCESS_KEY:-}" ] || [ -z "${HW_SECRET_KEY:-}" ]; then
  die "HW_ACCESS_KEY / HW_SECRET_KEY are required to obtain an SWR login token"
fi
require docker curl python3

REGISTRY="swr.${SWR_REGION}.myhuaweicloud.com"
DEST="${REGISTRY}/${SWR_ORG}/litellm:${VERSION}"

# --- temporary SWR credential -------------------------------------------------
log "requesting an SWR login credential"
creds="$(HW_REGION_NAME="$SWR_REGION" python3 - "$SWR_REGION" <<'PY'
import json, os, sys, base64, urllib.request, urllib.error
from datetime import datetime, timezone

region = sys.argv[1]
ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()

auth = {
    "auth": {
        "identity": {
            "methods": ["hw_ak_sk"],
            "hw_ak_sk": {"access": {"key": ak}, "secret": {"key": sk}},
        },
        "scope": {"project": {"name": region}},
    }
}
req = urllib.request.Request(
    "https://iam.myhuaweicloud.com/v3/auth/tokens",
    data=json.dumps(auth).encode(),
    method="POST",
)
req.add_header("Content-Type", "application/json;charset=utf8")
req.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
with urllib.request.urlopen(req, timeout=25) as resp:
    token = resp.headers["X-Subject-Token"]

# POST, not GET: GET answers 404 "method not found".
req = urllib.request.Request(
    f"https://swr-api.{region}.myhuaweicloud.com/v2/manage/utils/secret",
    method="POST",
)
req.add_header("X-Auth-Token", token)
try:
    with urllib.request.urlopen(req, timeout=25) as resp:
        body = json.load(resp)
except urllib.error.HTTPError as exc:
    sys.exit(f"SWR secret request failed: {exc.code} {exc.read()[:200].decode()}")

auths = body.get("auths") or {}
if not auths:
    sys.exit("SWR returned no auths - is the region/endpoint correct?")
blob = next(iter(auths.values()))["auth"]
print(base64.b64decode(blob).decode(), end="")
PY
)"

# creds is "user:password" - avoid putting the password on a command line.
IFS=: read -r SWR_USER SWR_PASS <<<"$creds"
printf '%s' "$SWR_PASS" | docker login "$REGISTRY" --username "$SWR_USER" --password-stdin >/dev/null
ok "logged in to $REGISTRY"

# --- mirror -------------------------------------------------------------------
# push-image.sh does preflight (network + auth + disk), the pull if needed, the
# push with pipefail, and verifies the manifest afterwards.
"$(repo_root)/scripts/push-image.sh" "${SRC_REPO}:${VERSION}" "$DEST"

cat <<EOF

Image mirrored to $DEST (terraform output litellm_image already points here).

Create the pull secret on the bastion (credential valid 24h):

  kubectl -n litellm create secret docker-registry swr-cred \\
    --docker-server=$REGISTRY \\
    --docker-username=$SWR_USER --docker-password=<the same password>

Then run deploy-app: pods pull over the intranet from SWR (100.125.x), never
from the public internet.
EOF
