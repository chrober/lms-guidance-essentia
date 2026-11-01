#!/usr/bin/env python3
"""Branch-only real-Lyrion catalog identity gate; no Essentia feature claims.

'prepare' writes three original, deterministic PCM WAV files into a throwaway
CI /music volume. 'verify' requests a scan of *that* isolated Lyrion server,
and requires three distinct real catalog IDs with exact local file URLs.
No players, plugin providers, native executables or live Pi are involved.
"""
import json
import math
import os
from pathlib import Path
import struct
import sys
import time
from urllib.parse import unquote, urlsplit
from urllib.request import Request, urlopen
import wave

BASENAMES = ("seed.wav", "candidate-a.wav", "candidate-b.wav")
RELATIVE_DIR = "essentia-staging"
BASE = "http://127.0.0.1:19092/jsonrpc.js"


def prepare(music_dir):
    root = Path(music_dir).resolve(strict=True)
    target = root / RELATIVE_DIR
    target.mkdir(mode=0o755, exist_ok=False)
    for index, filename in enumerate(BASENAMES):
        with wave.open(str(target / filename), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(8000)
            frequency = 330 + index * 110
            samples = b"".join(
                struct.pack("<h", round(2500 * math.sin(
                    2 * math.pi * frequency * frame / 8000)))
                for frame in range(8000)
            )
            handle.writeframes(samples)
    assert len(list(target.iterdir())) == len(BASENAMES)
    print("PASS: three deterministic synthetic PCM WAV sources prepared (no user audio)")


def rpc(command):
    payload = json.dumps({
        "id": 1, "method": "slim.request", "params": ["", command],
    }).encode("utf-8")
    with urlopen(Request(
        BASE, data=payload,
        headers={"Content-Type": "application/json",
                 "User-Agent": "Essentia-branch-only-catalog-identity/1"},
    ), timeout=8) as response:
        body = json.load(response)
    if not isinstance(body, dict) or not isinstance(body.get("result"), dict):
        raise RuntimeError("Lyrion JSON-RPC did not return a result object")
    return body["result"]


def read_track_rows(result):
    """Accept LMS's titles_loop/songs_loop aliases, never synthesize IDs."""
    loops = [value for key, value in result.items()
             if key.endswith("_loop") and isinstance(value, list)]
    if len(loops) != 1:
        return {}
    rows = {}
    for item in loops[0]:
        if not isinstance(item, dict):
            raise ValueError("unexpected Lyrion catalog row")
        track_id, url = item.get("id"), item.get("url")
        if not isinstance(url, str):
            raise ValueError("Lyrion did not return original track URL")
        parts = urlsplit(url)
        if parts.scheme != "file" or parts.netloc or parts.query or parts.fragment:
            raise ValueError("nonlocal/ambiguous track URL from isolated catalog")
        path = unquote(parts.path)
        prefix = "/music/" + RELATIVE_DIR + "/"
        if not path.startswith(prefix):
            raise ValueError("catalog contained an unexpected source root")
        key = path[len(prefix):]
        if key not in BASENAMES or key in rows:
            raise ValueError("unexpected or duplicate Lyrion file identity")
        if isinstance(track_id, bool) or not str(track_id).isdigit() or int(track_id) < 1:
            raise ValueError("no real positive Lyrion track ID")
        rows[key] = {"lms_track_id": int(track_id), "source_url": url,
                     "host_path": path, "root_relative_key": RELATIVE_DIR + "/" + key}
    if len({row["lms_track_id"] for row in rows.values()}) != len(rows):
        raise ValueError("ambiguous Lyrion catalog IDs")
    return rows


def verify(evidence):
    if os.environ.get("STAGING_TRACK_CATALOG") != "true":
        raise RuntimeError("explicit real-track staging-only opt-in missing")
    # This call is restricted to the loopback-only disposable Lyrion container.
    # Never use this script with a production server or personal library.
    rpc(["pref", "audiodir", "/music"])
    current = rpc(["pref", "audiodir", "?"])
    if current.get("_audiodir") != "/music":
        raise RuntimeError("disposable server did not accept isolated /music root")
    rpc(["rescan"])

    deadline = time.monotonic() + 180
    last_observation = "no catalog rows yet"
    while time.monotonic() < deadline:
        try:
            result = rpc(["songs", 0, 10, "tags:uf"])
            rows = read_track_rows(result)
            last_observation = "catalog rows: " + str(len(rows))
            if (len(rows) == len(BASENAMES)
                    and set(rows) == set(BASENAMES)
                    and str(result.get("rescan", "0")) not in ("1", "true")):
                # Verify each Lyrion ID resolves back to that same URL.
                for filename, row in rows.items():
                    detail = rpc(["songinfo", 0, 30,
                                  "track_id:" + str(row["lms_track_id"]), "tags:uf"])
                    urls = [str(value) for key, value in detail.items()
                            if key == "url" or key == "_url"]
                    if row["source_url"] not in urls:
                        raise ValueError("Lyrion track ID lookup did not preserve " + filename)
                proof = {"schema": "lyrion-real-catalog-identity-v1",
                         "origin": "isolated-github-actions-lyrion-9.1.2",
                         "kind": "synthetic-audio-real-lms-catalog",
                         "feature_analysis_performed": False,
                         "native_spi_invoked": False,
                         "tracks": [rows[key] for key in BASENAMES]}
                dest = Path(evidence)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(json.dumps(proof, indent=2, sort_keys=True) + "\n",
                                encoding="utf-8")
                print("PASS: three real scanned Lyrion catalog IDs and source URLs round-trip")
                for name in BASENAMES:
                    print("  " + name + ": catalog id " + str(rows[name]["lms_track_id"]))
                print("PASS: no feature data, native scoring or active playlist influence")
                return
        except (OSError, ValueError, TimeoutError) as exc:
            last_observation = type(exc).__name__ + ": " + str(exc)
        time.sleep(3)
    raise RuntimeError("real Lyrion catalog not ready within 180s (" +
                       last_observation + ")")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("prepare", "verify"):
        sys.exit("usage: ci_lyrion_catalog_identity.py prepare MUSIC_DIR | verify EVIDENCE_JSON")
    if sys.argv[1] == "prepare":
        prepare(sys.argv[2])
    else:
        verify(sys.argv[2])
