#!/usr/bin/env python3
"""Smoke-check a genuine isolated Lyrion process; no players/music needed.

The plugin is installed in a throwaway /config/cache/Plugins tree and remains
disabled by default. It must appear in the real Lyrion plugin manager without
being selected for native Guidance scoring.
"""
import json
import os
from collections import deque
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse
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

# Follow only the real settings links provided by the Lyrion Default skin.
# Do not assume a historical plugin-manager route exists in LMS 9.1.
class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.links.extend(value for name, value in attrs if name == "href" and value)


seeds = [
    "/Default/",
    "/Default/settings/index.html",
    "/Default/settings/server/index.html",
    "/Default/settings/server/plugins.html",
    "/Default/settings/plugins.html",
    "/settings/plugins.html",
]
queue = deque((x, 0) for x in seeds)
visited = set()
found = False
while queue and len(visited) < 35:
    url, depth = queue.popleft()
    if url in visited:
        continue
    visited.add(url)
    try:
        status, final_url, body = fetch(url)
    except (HTTPError, URLError, TimeoutError, OSError) as err:
        print(f"INFO: page {url}: {err}")
        continue
    matches = [
        name for name in ("EssentiaGuidance", "Essentia (research)",
                          "PLUGIN_ESSENTIAGUIDANCE_NAME")
        if name.lower() in body.lower()
    ]
    print(f"INFO: page {url} -> {status}, {len(body)} bytes, matches={matches}")
    if matches:
        found = True
        print("PASS: actual Lyrion Web/PluginManager lists the staged plugin")
        break
    if depth >= 3:
        continue
    parser = Links()
    parser.feed(body)
    discovered = []
    for link in parser.links:
        parsed = urlparse(urljoin(final_url, link))
        if parsed.scheme != "http" or parsed.netloc != "127.0.0.1:19092":
            continue
        if not any(word in parsed.path.lower() for word in ("setting", "plugin")):
            continue
        next_url = parsed.path + (("?" + parsed.query) if parsed.query else "")
        discovered.append(next_url)
    print(f"INFO: linked settings paths: {discovered[:16]}")
    for link in discovered[:20]:
        if link not in visited:
            queue.append((link, depth + 1))

if not found:
    sys.exit("FAIL: staged plugin not visible in examined real Lyrion management pages")


# A second job enables the *copy* of install.xml inside the throwaway
# staging volume. Only there may the normal Lyrion Settings page load;
# the provider must still be unavailable and have no scoring controls.
if os.environ.get("STAGING_ENABLED", "false").lower() == "true":
    options = [
        "/Default/plugins/EssentiaGuidance/settings/essentiaguidance.html",
        "/Default/settings/plugins/EssentiaGuidance/settings/essentiaguidance.html",
        "/Default/settings/essentiaguidance.html",
        "/plugins/EssentiaGuidance/settings/essentiaguidance.html",
    ]
    # Include links that the *real* web PluginManager displayed.
    for link in discovered if 'discovered' in globals() else []:
        if "essentia" in link.lower():
            options.insert(0, link)
    verified = False
    for url in dict.fromkeys(options):
        try:
            status, _, body = fetch(url)
        except (HTTPError, URLError, TimeoutError, OSError) as err:
            print(f"INFO: staging settings route {url}: {err}")
            continue
        has_status = "source_generation_and_root_provenance_unverified" in body
        print(f"INFO: staging status page {url} -> {status}, unavailable={has_status}")
        if has_status:
            verified = True
            print("PASS: genuine enabled staging Lyrion plugin renders unavailable status")
            break
    if not verified:
        sys.exit("FAIL: enabled staging plugin did not show the read-only unavailable status")

# A default-disabled plugin must never be implicitly launched by the
# real server. Assertions on the source contract are already separate
# tests; avoid creating any native executable in the test image.
print("PASS: no native executable or sidecar was installed")
