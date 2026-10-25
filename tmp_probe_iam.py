#!/usr/bin/env python3
"""Verify AK/SK against the IAM token endpoint for both site domains.

Tries the public/China site and the international site, because an AK that is
valid on one returns 401 with the generic 'get token error' on the other.
"""
import base64
import hashlib
import hmac
import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()

BODY = json.dumps({
    "auth": {
        "identity": {
            "methods": ["hw_ak_sk"],
            "hw_ak_sk": {
                "access": {"key": ak},
                "secret": {"key": sk},
            },
        },
        "scope": {"project": {"name": "cn-southwest-2"}},
    }
})

for host in ("iam.myhuaweicloud.com", "iam.myhuaweicloud.eu",
             "iam-apigateway-proxy.myhuaweicloud.com"):
    url = f"https://{host}/v3/auth/tokens"
    req = urllib.request.Request(url, data=BODY.encode(), method="POST")
    req.add_header("Content-Type", "application/json;charset=utf8")
    req.add_header("X-Sdk-Date", datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            tok = resp.headers.get("X-Subject-Token", "")
            print(f"{host}: HTTP {resp.status} token_len={len(tok)}")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:220]
        print(f"{host}: HTTP {exc.code} {detail}")
    except Exception as exc:  # noqa: BLE001
        print(f"{host}: ERROR {type(exc).__name__}: {exc}")
