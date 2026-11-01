# Real Lyrion catalog identity gate — 1 November 2026

**Research branch only:** `feat/essentia-guidance-integration-design`, Draft PR #1.
This is a step beyond the 31 October plugin-discovery/settings smoke, **not**
the completed Windows-feature/native-SPI integration or a user-library test.

## What is being exercised

The existing pinned official **Lyrion Music Server 9.1.2** Docker smoke
workflow now contains a third, separately disposable job named
`real-synthetic-track-catalog`. Its music directory is populated
**before** booting LMS, using
`scripts/ci_lyrion_catalog_identity.py prepare` to write precisely
three deterministic, tiny, original PCM WAVs:
`essentia-staging/seed.wav`, `candidate-a.wav`, and
`candidate-b.wav`. These are generated signals, not user music and
**not analyzed by Essentia**.

After the usual genuine server readiness, plugin-manager discovery
and status-only unavailable page checks, `verify`:

1. Targets only the job's loopback HTTP JSON-RPC endpoint
   `127.0.0.1:19092`, sets/reads the **disposable** `audiodir=/music`,
   and explicitly requests a scan in the isolated server.
2. Polls the real `songs` catalog until it contains exactly the three
   expected file URLs without a live scan flag.
3. Demands positive, distinct, genuine Lyrion catalog IDs, lossless
   original `file://` URLs, canonical root-relative filename matches,
   and roundtrips each ID with a second `songs` query filtered by `track_id`.
4. Records a small JSON evidence file `catalog-identity.json`
   containing only the synthetic track URLs, catalog IDs and source
   paths. The result explicitly states that feature analysis and
   native SPI execution were **not** performed.

The two original smoke matrix jobs (default-disabled and enabled-copy
status-only) remain unchanged. No network player, production DSTM,
playlist/queue mutation, FFmpeg, analyzer or native Essentia provider is
present. Only loopback HTTP is published; the music volume is mounted
read-only. The test removes the container and root-owned disposable
filesystem via a path-checked cleanup step.

## Explicitly not proven

- The JSON-RPC catalog IDs are actual indexed LMS rows; they are **not
  yet an in-process `Slim::Schema::Track` object extraction test**.
  The next stage must use the real track objects, `->url`,
  `->path` and `->urlmd5` inside a trusted isolated host runtime.
- Synthesized audio is not a valid Windows `essentia-analyser` feature
  database. No native `describe -> prepare -> score -> close`
  happens in this added CI job, and no General Metric result exists.
- No authentic Windows/Pi root mapping, cross-catalog generation,
  source-byte attestation, native ARM build, or performance proof.
- The installed provider still reports `available=0` and its normal
  SPI config factory continues to fail closed.

## Acceptance gates after this test

Once the real catalog job passes, introduce a **trusted, local-only**
staging harness (not a public route or browser action) that retrieves
the exact indexed LMS `Slim::Schema::Track` objects and binds one
original seed plus 2–50 previously admitted candidates to the
corrected generic SPI v2 host anchor route. Compare all identities
with the strictly read-only Bliss and **manually imported, genuinely
Windows-analyzed** SQLite-v3 sidecar before a manual
`PassiveProbe::run()`. Insist on `signals=[]`, required cleanup and
neutral fail-closed behavior. The source-byte, root and generation
limits are intentionally not promoted to production trust.

**No experimental merges to `main`, no production Pi operations and
no active Lyrion guidance.** The added gate is limited to synthetic
data in ephemeral GitHub Actions infrastructure.
