#!/usr/bin/env python3
"""Print the exact token request the SDK builds vs the one that works."""
import os

from huaweicloudsdkcore.auth.credentials import BasicCredentials

ak = os.environ["HW_ACCESS_KEY"].strip()
sk = os.environ["HW_SECRET_KEY"].strip()

for project in ("cn-southwest-2", None):
    cred = BasicCredentials(ak, sk, project) if project else BasicCredentials(ak, sk)
    tok = cred.get_token()
    print(f"project={project!r} -> token={'OK len=%d' % len(tok) if tok else 'EMPTY'}")

import inspect
from huaweicloudsdkcore.auth import credentials as c
src = inspect.getsource(c.BasicCredentials.get_token)
print("--- get_token source (first 60 lines) ---")
print("\n".join(src.splitlines()[:60]))
