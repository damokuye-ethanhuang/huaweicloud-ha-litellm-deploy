#!/usr/bin/env python3
"""Parse the CCE Kubernetes version lifecycle table from the official bulletin.

Source: https://support.huaweicloud.com/intl/zh-cn/bulletin-cce/cce_bulletin_0033.html
Rule stated on that page: the console offers the latest 3 commercial versions
plus the newest public-beta version; the API accepts any version still in
maintenance; EOS versions cannot create clusters.
"""
import json
import re
import sys
import urllib.request

URL = "https://support.huaweicloud.com/intl/zh-cn/bulletin-cce/cce_bulletin_0033.html"

req = urllib.request.Request(URL, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req, timeout=30) as resp:
    raw = resp.read().decode("utf-8", "replace")

text = re.sub(r"<script.*?</script>|<style.*?</style>", "", raw, flags=re.S)
text = re.sub(r"<[^>]+>", "\n", text)
import html as _h
text = _h.unescape(text)
flat = "\n".join(l.strip() for l in text.split("\n") if l.strip())

# Table rows look like:
# v1.36 | <state> | <something> | 2026年04月 | 2026年06月 | 2026年08月 | 2028年08月
ROWS = re.findall(
    r"(v1\.\d{2})\s*\n\s*([^\n]{0,12})\s*\n\s*[^\n]{0,20}\n\s*(\d{4}年\d{2}月)\s*\n\s*"
    r"(\d{4}年\d{2}月)\s*\n\s*(\d{4}年\d{2}月)\s*\n\s*(\d{4}年\d{2}月)",
    flat,
)

rows = []
for ver, state, beta, ga, _, eos in ROWS:
    rows.append({
        "version": ver,
        "state": state.strip(),
        "ga": ga.replace("年", "-").replace("月", ""),
        "eos": eos.replace("年", "-").replace("月", ""),
    })

# Deduplicate, keep first occurrence (newest first on the page)
seen, uniq = set(), []
for r in rows:
    if r["version"] in seen:
        continue
    seen.add(r["version"])
    uniq.append(r)

ga_versions = [r["version"] for r in uniq if "商用" in r["state"]]
beta_versions = [r["version"] for r in uniq if "公测" in r["state"]]

print(json.dumps({
    "source": URL,
    "api_supported": ga_versions + beta_versions,
    "console_create": ga_versions[:3] + beta_versions[:1],
    "rows": uniq,
}, ensure_ascii=False, indent=2))
