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

## Found generic host blocker

During verification the shared host
[`lms-bliss-guidance-host/Plugins/BlissGuidance/Runtime.pm`]
(https://github.com/chrober/lms-bliss-guidance-host/blob/main/Plugins/BlissGuidance/Runtime.pm)
was found to hardcode `anchors => []` for every
native `prepare` request. The existing SPI-v2 request format
already includes `anchors`; the Essentia native provider
requires one verified global seed. This is a **generic host
transport gap**, not justification for Essentia code in
BlissMixerLab or a second native subprocess runner.

Proposed generic-only host line (not yet applied to that repo):

```perl
anchors => ref($request->{anchors}) eq 'ARRAY' ? $request->{anchors} : [],
```

The existing host's generic `Runtime::score_batch` regression
test should verify forwarded and absent anchors. Separately,
the actual generic Lab call path must supply a trustworthy
seed/candidate cohort with aligned IDs; its existing
`profile_from_provider` has no anchor and the
`lastfm_evidence_from_provider` path creates synthetic
`seed-1` IDs, so additional provider-neutral host flow review
is needed. Do not modify Lab to understand Essentia.

At the time of this update the current GitHub integration does
not have write access to `lms-bliss-guidance-host`, so no
change was made there. The provider-only offline native test
does **not** validate this missing generic transport step.

## Next gated milestone

After a reviewed provider-neutral host fix, make the Lyrion
plugin installable in an explicit **passive-only** opt-in mode,
using trusted candidate/seed identities and the manually
transferred read-only sidecar, without automatic scanning.
Only then run a bounded real-server pilot on the Pi. Keep
the normal provider unavailable until those conditions are
demonstrated, and do not merge prematurely.
