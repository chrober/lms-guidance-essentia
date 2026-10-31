# Provider-side content provenance for SPI-v2 research — 31 October 2026

## Status and scope

**Implemented and tested only in the provider's Draft PR #1.**
Source attestation is offline research code and is **not** connected to the
installed Lyrion plugin, web UI, live mix path, or normal native SPI factory.
`EssentiaGuidance::Provider` still returns `available=0` regardless of
whether an offline attestation succeeds. The generic BlissMixerLab host
and the `bliss-playlist-guidance-spi` v2 wire contract are unchanged.

## Concrete producer evidence (scanner SQLite schema v3)

`essentia-analyser` currently writes in the same SQLite transaction:

- `feature_tracks(track_file, model_id, model_key, audio_sha256,
  scores_f32_le, ...)`: `audio_sha256` is **SHA-256 of the original raw
  music file bytes** (`features.rs` calls `sha256_file(path)`, not SHA-256
  of the decoded PCM stream).
- `feature_track_state(track_file, model_id, file_size, modified_ns,
  model_key)`: file stat captured during the source analysis.
- `feature_models(model_key, validated_against_essentia, ...)`: selected
  model fingerprint/validation state.

These fields permit a per-file proof without schema changes,
but **do not contain** a Lyrion scan-generation token or the root
namespace of the file actually decoded by the scanner.

## Offline evidence algorithm

`SourceProvenance::attest_cohort(research_only => 1, ...)` requires
1 seed, 2–50 host-admitted candidates, one requested model fingerprint,
1–32 canonical existing POSIX music directories, and pinned query-only
Bliss/Essentia database connections. It:

1. Resolves each trusted host track path to exactly one configured
   canonical music root. Rejects CUE/URL streams, symlink aliases,
   parent traversal, nested-root ownership ambiguity and duplicates.
2. Derives the exact relative `TracksV2.File` key, verifies precisely
   one nonignored Bliss row and one scanner model-head/state row.
3. Rejects the whole cohort if the same relative key exists under
   another configured music root. SQLite-v3 keys are not root-qualified;
   a nonunique key cannot safely name two recordings.
4. Requires the expected model key, a validated model, matching
   `feature_track_state.file_size` and a lowercase 64-character
   `feature_tracks.audio_sha256`.
5. Opens the actual source file as bytes and streams SHA-256, bounded
   by configurable per-file and whole-cohort byte caps. Checks device,
   inode, size and modification time on the descriptor and path
   before and after hashing to reject obvious concurrent edits.
   Any missing, replaced or differently hashed file fails the whole
   cohort. `modified_ns` from a different scan machine is not treated
   as an authoritative current-machine timestamp; content SHA is.

The successful result contains exactly the original seed/candidate
identities, their exact scanned keys, number of roots and bytes hashed.
It contains **no** `generation_validated=true` claim.

`SpiResourceBundle::assemble_research_bundle` supports
`verify_audio_content => 1`. That opt-in passes its audited keys to the
existing SHA-256-bound identity artifact writer and creates the same
small read-only SQLite-v3 projection. The `prepare.artifacts` and
`prepare.resources` shapes are unchanged; no new SPI operation exists.
The `audio_content_audit` summary returned to the **offline caller**
is never forwarded as an active guidance signal.

## Verification

- `tests/source_provenance.t` exercises real files and SQLite-v3 source
  tables with two distinct roots, a deliberate relative-key collision,
  a same-size content rewrite, forged model key, duplicate identities,
  symlink/path traversal, nonlocal source and hash byte budgets.
- `tests/spi_resource_native_jsonl.t` now builds a **two-root source
  fixture**, hashes its original test file bytes, checks the scanner
  hashes, projects the three verified feature rows and executes the
  actual independent Rust SPI-v2 binary through
  `describe -> prepare -> score -> close`.
- All returned native `signals=[]`. The offline results explicitly
  preserve `generation_verified=false`.
- [Verified GitHub CI run](https://github.com/chrober/lms-guidance-essentia/actions/runs/41197901541):
  113 Perl checks plus 15 real native process assertions, all green.

## Guarantees and remaining limitations

**Established for the audited offline cohort:** the selected original
music file bytes match the scanner's recorded SHA-256 for the exact
chosen model and relative Bliss key, and no configured alternate root
currently contains a colliding key. This is **cohort-level content
integrity**, not proof that Bliss and Essentia imported the same entire
library generation. A continuously changing filesystem is not an
atomic snapshot. The paths and root set must originate from a trusted
host context; they cannot come from a browser request.

**Not established:** host scan generation/epoch, a shared host/scanner
root manifest, full-catalogue equality, no changes after the verification
window, CUE identity, Windows/UNC portability, native filesystem hard-link
aliasing, or safe sub-500ms latency for full-file hashing. Even one
long FLAC file can be expensive to hash on a Raspberry Pi.

**Production gate stays closed.** A later provider-controlled scan
generation / root-map witness, or another explicitly reviewed per-track
freshness contract, must be built with the scanner and host before the
native config factory is allowed to return an executable resource.
Live scoring must never hash 2–50 entire files synchronously.

## Repository boundary

- `lms-guidance-essentia`: all source verification and resource
  preparation code and offline tests.
- `bliss-guidance-essentia`: unchanged native SPI-v2 JSONL provider;
  no playlist, queue or scanner writes.
- `lms-blissmixer-lab`: **no changes**. No Essentia imports or private
  host-side mapping. Closed PR #3 remains closed.
- `essentia-analyser`: existing v3 metadata read-only; **not changed**
  by this work.
