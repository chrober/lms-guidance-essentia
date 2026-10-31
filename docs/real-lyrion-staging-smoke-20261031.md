# Real Lyrion staging smoke: passive Essentia shell (31 October 2026)

**Result:** the official Lyrion Music Server 9.1.2 process has now
loaded the actual staging plugin layout. Two disposable GitHub Actions
instances verify separate conditions; neither uses the production Pi.

## Reproducibility and isolation

- Source: **research branch only**,
  `feat/essentia-guidance-integration-design`.
- Workflow: `/.github/workflows/real-lyrion-staging-smoke.yml`.
- Test client: `/scripts/ci_lyrion_staging_smoke.py`.
- Official image: `lmscommunity/lyrionmusicserver:9.1.2-stable`, immutable
  manifest SHA-256:
  `a8709abda8a80766274abeb44015189b7e050eb1a6372678dcb077eb8c3a1e21`.
  The port is `19092:19092` on `127.0.0.1`, with
  `HTTP_PORT=19092` as required by the official Docker image.
- Separate throwaway runner volumes: empty `/music` (read-only),
  `/playlist`, `/config`. The plugin directory is
  `/config/cache/Plugins/EssentiaGuidance`, per official image
  documentation. No 3483 (SlimProto discovery) or 9090 (CLI)
  ports are published. No running player or Pi is involved.
- The source `install.xml` has `disabled` defaults on every
  platform. In exactly **one** CI matrix job, the file is changed to
  `<other>enabled</other>` only in the copied ephemeral directory
  under `/config/cache/Plugins`; the Git checkout and default
  distribution remain disabled.
- The staged copy contains **no native binary**, actual audio,
  ONNX model, Essentia feature SQLite, real music catalog, or
  scanner schedule. Both containers are forcibly removed after
  the test. Logs are retained in a short-lived Actions artifact.

## Real runtime assertions

The independent Lyrion process answers `serverstatus` through
`/jsonrpc.js` and reports version **9.1.2**.

**Job 1: disabled by default.** The actual Default-skin management
page `/Default/settings/server/plugins.html` lists
`EssentiaGuidance` and `Essentia (research)`. No provider
settings page or native executable is activated by this test.

**Job 2: explicitly enabled in a disposable copy.** The same real
plugin manager lists the provider. The actual Lyrion settings page
`/Default/plugins/EssentiaGuidance/settings/essentiaguidance.html`
renders `source_generation_and_root_provenance_unverified`.
This proves that the installed `Plugin.pm`, `Settings.pm`, string
resources, URL and server-side status method are wired correctly in
a running LMS instance, not merely in Perl stubs.

**Proof:** [real LMS matrix CI #41235274969]
(https://github.com/chrober/lms-guidance-essentia/actions/runs/41235274969)
reports both jobs **PASS**. Follow-up workflow pins the exact Docker
image digest as an additional reproducibility measure.

Independent static and native-JSONL CI also verifies normal Guidance
`status.available=0`, config/acquisition rejection, the passive-only
manual one-seed route and fail-closed native `signals=[]`.

## Strict limitation

This real-server smoke is **plugin installation / discovery / settings
only**. It does *not* claim a real DSTM candidate batch or actual
`Slim::Schema::Track` instance, actual Windows `essentia-analyser`
features, Pi ARM binary, Pi/Windows same-source-byte proof, stable
cross-catalog scan generation or a completed live guidance execution.
The normal Essentia provider remains unavailable and its native config
factory always throws, even in the explicitly enabled **test** job.

The next test needs a small, explicitly selected and genuinely
Windows-analyzed cohort with verified Lyrion file keys, plus an
isolated real-Lyrion runtime and a locally built, pinned native
binary. It must remain separate from production and cannot select
different candidates or rewrite the original model validation flag.

All involved PRs remain **Draft**, no merges into any `main` branch,
no automatic update, no real Pi deployment and no playlist influence.
