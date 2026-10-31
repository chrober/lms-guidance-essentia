# Bliss Guidance: Essentia (Lyrion provider)

## Read-only catalog fingerprint and root-map freshness — 31 October 2026

`EssentiaGuidance/CatalogFingerprint.pm` now creates a deterministic
bounded digest of every eligible `TracksV2.File` plus an explicit
root-ID / canonical-host-root mapping. Its `assert_fresh()` method
reopens Bliss in a **new** readonly SQLite transaction, so a concurrent
rescan or changed host roots invalidate the previous fingerprint
instead of being hidden by the original pinned WAL snapshot.

Optional offline-only `SpiResourceBundle` `catalog_roots` admission
requires full-file SHA-256 content audit, verifies exact configured
root ownership, and rechecks the full catalog before returning its
existing SPI-v2 resource envelope. An additional recheck after the
native process can detect a catalog change during the session.

[Final CI](https://github.com/chrober/lms-guidance-essentia/actions/runs/41200038531)
passes **136 Perl + 20 actual native SPI tests**, including a deliberate
catalog update after successful native scoring. **No authenticated
Lyrion scan epoch or scanner-side root receipt exists yet**. Root IDs
supplied to this offline test are not themselves authoritative; the
provider stays unavailable and no full-catalog walk runs live.

See [verified upstream scan event semantics and outstanding
generation/root contract](docs/catalog-generation-and-root-contract-20261031.md).

## Offline content provenance across multiple roots — 31 October 2026

The provider now has an optional **offline-only** SHA-256 source attestor:

- Reads the existing scanner SQLite-v3 `audio_sha256`, `feature_track_state`
  and validated model fingerprint; hashes the actual full local audio files.
- Accepts distinct music roots only when every chosen track has exactly
  one owning root and no other configured root contains the same
  relative scanner key.
- A separate `verify_audio_content => 1` research mode composes this
  proof into the existing bounded SQLite resource and SHA-256-bound
  native SPI artifact. Full two-root `describe/prepare/score/close`
  integration tests pass against the unchanged Rust binary.
- **Never** interprets matching hashes as an authoritative shared
  Lyrion/Essentia scan generation. Normal provider status remains
  unavailable; full-file hashing is not permitted in a live mixer call.

[Proof, negative tests, CI evidence and remaining requirements]
(docs/audio-content-provenance-20261031.md).
## Progress: discoverable API facade and SPI resource assembly

Research implementation on Draft PR #1 now contains:

- `EssentiaGuidance/Plugin.pm` and `Provider.pm`: ordinary Lyrion
  `guidance_provider_*_v1` discovery and SPI-v2 metadata, based on the
  existing provider kit. The provider **always reports unavailable**
  (`source_generation_and_root_provenance_unverified`) and its native
  configuration factory always rejects calls. No special host API exists.
- `SpiResourceBundle.pm`: **offline research-only** composition of the
  provider's exact-key verifier and bounded SQLite-v3 projection into
  ordinary SPI `prepare.artifacts` and `prepare.resources`, with one
  unchanged global seed, 2–50 host-admitted candidates and pinned model.
  The caller owns temporary resource cleanup; no subprocess is started
  by this module.
- Contract and negative tests cover false trust flags, unverified roots,
  missing features, strict resource bounds, source read-only behavior
  and canonical JSONL transport with the independent native provider.

The [native integration CI](https://github.com/chrober/lms-guidance-essentia/actions/runs/41197043974)
passes 94 offline Perl tests and 12 true native SPI JSONL assertions, while
preserving `signals=[]` and identical host-admitted candidate identities.

**This is not an installable or functional Lyrion plugin**: no
`install.xml`, settings UI, release binary, authoritative source-generation
proof or multi-root source witness has been added. The positive research
fixture has no authority to activate production status or influence playback.

See [SPI-only provider ownership and gates]
(docs/provider-owned-spi-shadow-20261031.md).

## Architecture correction (31 October 2026)

**BlissMixerLab is provider-neutral.** The Lyrion plugin in this repository,
not the Lab host, owns Essentia-specific identity, root and source-generation
verification as well as bounded read-only feature projection. The native
provider is invoked **only through the existing Guidance SPI v2**; the
Lab-owned direct Essentia subprocess and modules were deleted.

This branch now contains experimental `EssentiaGuidance/ExactIdentity.pm`
and `EssentiaGuidance/BoundedSnapshot.pm` with independent offline tests.
**The plugin remains non-installable and not registered**, with no
`Plugin.pm`, runtime integration or active guidance. A missing authoritative
cross-database generation/root witness still blocks real host use.

See [provider-owned SPI and provenance contract]
(docs/provider-owned-spi-shadow-20261031.md).

**Status: Lyrion plugin remains design-only and is not installable. The separate native [Essentia Guidance Draft PR #1](https://github.com/chrober/bliss-guidance-essentia/pull/1) now contains a real, tested, shadow-neutral SPI v2 executable. It emits no active Guidance signals and has not been packaged or connected to Lyrion hosts.**

A future independently installable, passive Lyrion guidance provider, following the conventions of [`lms-guidance-lastfm`](https://github.com/chrober/lms-guidance-lastfm) and [`lms-guidance-library-signals`](https://github.com/chrober/lms-guidance-library-signals). It will expose an optional [`bliss-guidance-essentia`](https://github.com/chrober/bliss-guidance-essentia) native provider using the host-independent [`essentia-similarity`](https://github.com/chrober/essentia-similarity) engine to compatible Lyrion hosts: [BlissMixerLab](https://github.com/chrober/lms-blissmixer-lab) first, then [Better Call Bliss](https://github.com/chrober/lms-better-call-bliss).

Lyrion hosts discover installed guidance providers, keep them opt-in, resolve trusted configuration and invoke native hosts implementing the [`bliss-playlist-guidance-spi`](https://github.com/chrober/bliss-playlist-guidance-spi) version 2. This plugin must **not** modify an already-playing queue, accept unauthorized database paths from browser input, fetch ONNX models during playback, or bypass Bliss admission/repeat/route constraints.

This repository is the Lyrion configuration/packaging surface, **not the provider-side Rust scoring implementation**. Consult [integration and acceptance contract](docs/lyrion-provider-contract.md) before implementation. Start from [`lms-bliss-guidance-provider-kit`](https://github.com/chrober/lms-bliss-guidance-provider-kit) and the current working Library Signals provider rather than reinventing discovery or settings UI.

## Current practical integration blocker

Source inspection of `lms-blissmixer-lab/BlissMixerLab/GuidanceProviderAdapter.pm` (30 Oct 2026) confirms that the current SPI candidate envelope sets `database_file => undef`, while the available candidate identities include the LMS URL and `urlmd5`. Neither value is automatically the scanner sidecar's exact `feature_tracks.track_file`. The native provider now requires a trusted, host-created SHA-256-bound `essentia-exact-track-keys-v1` artifact with the exact source and candidate mappings. **This plugin must not claim availability until the host mapping is implemented.** See [native provider README](https://github.com/chrober/bliss-guidance-essentia/blob/feat/essentia-guidance-integration-design/README.md) and [Lyrion provider contract](docs/lyrion-provider-contract.md).

## Offline feature producer ownership

The **canonical** Rust offline scanner and original Essentia C++ worker are now maintained in [`chrober/essentia-analyser`](https://github.com/chrober/essentia-analyser) (extraction [PR #1 merged](https://github.com/chrober/essentia-analyser/pull/1)). It generates the precomputed versioned SQLite-v3 feature sidecar; no analysis binaries, ONNX models or upstream Essentia worker are launched at Guidance scoring time. [`chrober/bliss-mood-poc`](https://github.com/chrober/bliss-mood-poc) remains the **research/experimentation** repository for WP1/WP2/WP3 and historical scanner reproducibility. Actual third-party native release approval is still blocked by the producer's separate license gates.
