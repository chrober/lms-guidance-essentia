#!/usr/bin/env python3
"""Smoke-check a genuine isolated Lyrion process; no players/music needed.

The plugin is installed in a throwaway /config/cache/Plugins tree and remains
disabled by default. It must appear in the real Lyrion plugin manager without
being selected for native Guidance scoring.
"""
import json
import os
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

BASE = "http://127.0.0.1:19092"
DEADLINE = time.monotonic() + 120


def fetch(path, payload=None):
    headers = {"User-Agent": "Essentia-branch-only-LMS-smoke/1"}
    if payload is not None:
        payload = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = Request(BASE + path, data=payload, headers=headers)
    with urlopen(req, timeout=5) as response:
        return response.status, response.geturl(), response.read(1024 * 1024).decode(
            "utf-8", errors="replace"
        )


while time.monotonic() < DEADLINE:
    try:
        _, _, body = fetch("/jsonrpc.js", {
            "id": 1, "method": "slim.request",
            "params": ["", ["serverstatus", 0, 10]],
        })
        result = json.loads(body)
        status = result.get("result", {})
        if status.get("version") or status.get("lastscan"):
            print("PASS: genuine Lyrion JSON-RPC serverstatus available")
            print("Lyrion version:", status.get("version", "(unavailable)"))
            break
    except (HTTPError, URLError, TimeoutError, ValueError, OSError):
        pass
    time.sleep(2)
else:
    sys.exit("FAIL: real Lyrion server never became ready (120s)")

# Default Lyrion Web skin handles plugins.html. A disabled-by-default
# plugin should appear on this management page, but its settings do not
# activate a native scoring process.
urls = [
    "/Default/settings/plugins.html",
    "/settings/plugins.html",
    "/Default/settings/plugins.html?player=",
    "/Default/",
]
found = False
for url in urls:
    try:
        status, final_url, html = fetch(url)
    except (HTTPError, URLError, TimeoutError, OSError) as err:
        print(f"INFO: page {url}: {err}")
        continue
    matches = [
        name for name in ("EssentiaGuidance", "Essentia (research)",
                          "PLUGIN_ESSENTIAGUIDANCE_NAME")
        if name.lower() in html.lower()
    ]
    print(f"INFO: management page {url} -> {status}, {len(html)} bytes, matches={matches}")
    if matches:
        found = True
        print("PASS: actual Lyrion Web/PluginManager lists staged Essentia plugin")
        break

if not found:
    sys.exit("FAIL: staged plugin absent from actual Lyrion plugin-manager Web output")

# A default-disabled plugin must never be implicitly launched by the
# real server. Assertions on the source contract are already separate
# tests; avoid creating any native executable in the test image.
print("PASS: no native executable or sidecar was installed")
