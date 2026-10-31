# Manual Windows-sidecar pilot: bounded passive SPI v2 on the Pi

**Status (31 October 2026):** provider-owned offline research helper,
not a deployed/registered Lyrion plugin. The separate
`bliss-guidance-essentia` native SPI is unchanged and continues to
return `signals=[]`. Generic BlissMixerLab, its mixer and playlist
selection remain unchanged.

## Scope deliberately excludes automatic library updates

The 65k+ song collection is manually analyzed on a Windows PC using
the original Essentia C++ worker, and a consistent SQLite-v3 feature
snapshot is copied to the Raspberry Pi 4B. No Lyrion `rescan done`,
`library changed`, scheduler, runtime ONNX, FFmpeg or analyzer process
is involved during mix creation. A three-song pilot (one seed +
two already-admitted candidates) is sufficient for initial evidence.

## New research implementation

`EssentiaGuidance/ImportedSidecarPilot.pm` provides
`assemble_pilot_bundle` with explicit `research_only=1`,
`passive_only=1`, `experimental_preview_opt_in=0|1`, one
canonical Pi music root, model ID/key, private workspace,
read-only Bliss and imported feature SQLite paths, one trusted
host seed and 2–50 previously admitted candidates.

It independently opens both SQLite-v3/Bliss databases with
`SQLITE_OPEN_READONLY`, freezes separate read transactions,
requires one exact nonignored Bliss `TracksV2.File` match
and a corresponding `feature_tracks` + `feature_track_state`
row for **each** admitted track and the chosen model. The
model fingerprint, original source hash format and recorded file
size must match; an existing Pi audio file must resolve under
exactly one canonical host music root with the same byte length.
Source audio is **never hashed or decoded** in this first Pi pilot.

An unvalidated `feature_models.validated_against_essentia=0`
is **not rewritten or relabeled**. It requires the explicit
`experimental_preview_opt_in=1` argument and is passed unchanged
to the native `prepare.options`. The native provider already
supports experimental preview; it still emits no active
guidance signals. Validated models do not require a preview flag.

The helper reuses existing provider modules to create the
SHA-256-bound `essentia-exact-track-keys-v1` artifact and a private
<=4 MiB `essentia-feature-sqlite-v3` resource containing only
the selected 3–51 rows. Its `anchors`, `context`, `candidates`,
`options`, `artifacts` and `resources` are standard SPI-v2
values; no new field is added to the protocol. Failed or
partially analyzed cohorts fail **as one whole batch** rather
than dropping candidates or choosing a new seed.

Returned **local-only** audit reports `model_status=experimental`
or `validated`, `source_bytes_verified=false`,
`catalog_generation_verified=false`,
`full_catalog_verified=false`. The caller owns deletion of
the private temporary directory after the test session.

## Verification

[CI run 41202318933](https://github.com/chrober/lms-guidance-essentia/actions/runs/41202318933)
passes the Perl suite and the independent Rust-native SPI process.
`tests/imported_sidecar_pilot.t` creates a Windows-origin
SQLite-v3 test database with an unvalidated genre model,
manually copies it to a distinct Pi-side file, verifies real
Pi-side file keys/sizes and model fingerprints, then executes
the native `describe -> prepare -> score -> close` sequence.
Negative cases cover disabled research mode, active-mode attempt,
missing experimental opt-in, wrong model key, multiple music roots,
duplicate candidates, absent features and changed file sizes.
The native result remains `signals=[]`.

## What this does **not** prove

- No validated musical ranking or active General Metric. The metric
  geometry has merely been exercised on an experimental model.
- No source-byte equality between the Pi's audio and the Windows
  analysis. Same-size replacements will escape this lightweight
  research check. Use the separate, costlier full-file
  `SourceProvenance.pm` offline auditor when content parity is needed.
- No authenticated Windows-to-Pi stable musicroot mapping; only
  one unambiguous host root is currently supported. The SQLite-v3
  `(track_file, model_id)` PK remains collision-prone across roots.
- No real-Lyrion plugin installation, discoverable available
  provider, runtime native configuration or host-exercised
  candidate batch. `Provider.pm` still returns `available=0`.
- The whole 65k catalog need not be fully covered or identical
  for this *passive* pilot. Missing/stale features remain neutral.

## Generic SPI host correction — isolated Draft PRs

GitHub repository access has been granted and the SPI-v2
`prepare.anchors` transport problem has been corrected **on a
dedicated research branch only**:

- [Shared host Draft PR #1](https://github.com/chrober/lms-bliss-guidance-host/pull/1),
  branch `fix/spi-v2-prepare-anchors`, forwards the trusted
  `request.anchors` array and preserves `[]` for callers without it.
  [CI run 41208151575](https://github.com/chrober/lms-bliss-guidance-host/actions/runs/41208151575):
  **10 tests PASS**.
- [Lab vendor Draft PR #5](https://github.com/chrober/lms-blissmixer-lab/pull/5),
  branch `test/spi-v2-anchor-forwarding-vendor`, updates only that
  same provider-neutral line in Lab's older copy, without importing
  unrelated upstream logging changes.
  [CI run 41208337308](https://github.com/chrober/lms-blissmixer-lab/actions/runs/41208337308):
  **267 Perl tests PASS**.
- `Better Call Bliss` carries only the shared controls/Policy and
  SettingsModel files in its current tree, not this Runtime.pm.

### Which host actually runs the Lab provider?

Lab's `_guidanceHostPayload()` already forwards `anchors` to its
native mixer via `/api/guidance/score`; the pinned native
`bliss-mixer` source also forwards `request.anchors` into
`GuidanceRequest::Prepare` with a native regression test.
Thus the shared Perl runtime patch fixes the **standalone generic
JSONL runtime**; it is not sufficient to populate missing seed
context in Lab's existing `profile_from_provider()` call.

The current `profile_from_provider()` uses an anchor-free global
score context. The separate `lastfm_evidence_from_provider()`
constructs host route IDs such as `seed-1`. Those IDs are valid
provider-neutral SPI IDs, but an Essentia exact-key artifact
must map its *same* anchor ID to the correct root-relative
`track_file`; it must not silently assume `seed-1` is an LMS URL.

### Dependency pin caveat

The native mixer release provenance pins `bliss-mixer` commit
`5f2430a` and its `bliss-playlist-guidance-spi` dependency to
`773b1a6`; at that pinned SPI commit, `GuidanceHostRequestV1`
and its JSON schema contain the optional `anchors` field.
The **current** `bliss-playlist-guidance-spi/main` lacks the
host request field. Do not assume an unpinned `main` build has
the same ABI/schema or silently change that contract. Review
source and pin compatibility separately before changing native
mixer releases.

### Cross-repository integration evidence

CI now pins shared-host research commit `d05a043b` alongside
the unchanged independent native Essentia SPI revision and
runs `ImportedSidecarPilot` through
`Plugins::BlissGuidance::Runtime::score_batch()` with the
actual `anchors`, `context` and `candidates` from its bounded
Windows-to-Pi sidecar projection. It additionally verifies
fail-closed behavior when the seed is missing or is replaced
with a synthetic unbound ID. Neither test runs an LMS
plugin, changes a player queue, or activates provider scoring.

## Next gated milestone

After a reviewed provider-neutral host fix, make the Lyrion
plugin installable in an explicit **passive-only** opt-in mode,
using trusted candidate/seed identities and the manually
transferred read-only sidecar, without automatic scanning.
Only then run a bounded real-server pilot on the Pi. Keep
the normal provider unavailable until those conditions are
demonstrated, and do not merge prematurely.
