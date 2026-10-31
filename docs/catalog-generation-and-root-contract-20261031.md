# Cross-source generation and root witness — design gate (31 October 2026)

**Status: offline catalog/root fingerprint implemented, authoritative shared
generation contract still a proposal.** Not implemented in the Lyrion
scanner lifecycle or normal provider factory. `Provider.pm` still returns
`available=0`, and generic BlissMixerLab/Guidance SPI v2 remain unchanged.

## Why a content SHA alone is insufficient

An exact LMS candidate URL, `TracksV2.File`, scanner `track_file` and
original-file SHA-256 can prove an individual cohort's recorded bytes;
they do not establish that the whole Bliss catalog and the scanner
database represent the same Lyrion scan generation. Multiple music
directories can contain the same relative path. SQLite-v3
`PRIMARY KEY(track_file,model_id)` cannot distinguish them. Reusing
timestamps, `rowid`, database inode or `PRAGMA data_version` as a shared
generation marker would be unsound.

## Verified upstream scan signal semantics

The actual [Lyrion server repository](https://github.com/LMS-Community/slimserver)
and [CLI database reference](https://lyrion.org/reference/cli/database/)
expose `rescan ?` (scanning-in-progress) and a
[`rescan done` notification](https://github.com/LMS-Community/slimserver/blob/public/9.2/Slim/Control/Request.pm)
plus `library changed`. `serverstatus` can report `lastscan`.
The upstream [scanner.pl](https://github.com/LMS-Community/slimserver/blob/public/9.2/scanner.pl)
marks scan state, incrementally commits during a scan, calls
`setLastScanTime` only if the importer reports changes, then runs
the final post-scan database helper.

**None is a durable immutable cross-database epoch.** The same `lastscan`
timestamp can survive an unchanged scan; notifications may be missed
across server/plugin restarts; metadata timestamps and the scanner's
read transaction are not a shared atomic snapshot. Treat them as
**invalidation/negative gates**, not a proof of matching generations.

## Implemented: bounded offline Bliss catalog and root fingerprint

`EssentiaGuidance/CatalogFingerprint.pm` now hashes all nonignored
`TracksV2.File` rows under one pinned, readonly SQLite transaction,
in deterministic binary collation order. An explicit provider-supplied
map of stable logical root IDs to canonical *host-local* physical
music roots is hashed separately. The combined versioned SHA-256 binds
both the entire eligible Bliss catalog and the host root configuration.
All keys are length-delimited UTF-8 fields and the scan has fixed
1-million-track / 64-MiB default bounds (256 MiB hard cap).

`CatalogFingerprint::assert_fresh` opens a **new** readonly SQLite
read transaction and recomputes both digests. Re-reading the original
WAL-pinned DB handle would silently miss a concurrent catalog change.
Duplicate eligible keys, overlapping/duplicate roots, noncanonical
paths, unbounded content, writable database handles and absent
explicit research opt-in all fail closed.

`SpiResourceBundle.pm` optionally accepts `catalog_roots` for offline
`verify_audio_content=1` research cohorts. It requires an exact
1:1 match with `media_dirs`, hashes the full catalog before creating
SPI resources, then performs the independent fresh-read check before
returning the bounded artifact/resource pair. The returned audit
fingerprint can be checked again **after** the native SPI exchange;
the native SPI wire schema is unchanged.

[Native integration CI](https://github.com/chrober/lms-guidance-essentia/actions)
covers the successful unchanged snapshot and deliberately changes
the Bliss catalog after the native SPI exchange to ensure a
**post-run recheck rejects the old fingerprint**. Independent
`tests/catalog_fingerprint.t` exercises WAL concurrent modification,
root-ID changes, invalid roots, duplicate key collisions and limits.

**Crucial limits:** Root IDs are caller-provided and currently **not**
authenticated by an authoritative Lyrion root registry. A content
fingerprint is not a durable host generation or scanner-side receipt.
It detects differences between snapshots, not intervening changes
that are reversed between reads (ABA). Do not call the fingerprint
`lyrion-library-generation-v1` or use it to enable `Provider.pm`.
Full-catalog enumeration is intentionally **offline**; no full scan
or file hashing may run in the latency-sensitive mixer scoring path.
## Proposed contracts (not yet source-backed)

1. **Host-owned catalog witness**: obtain from an authoritative Lyrion
   scan-completion/reindex lifecycle, not an arbitrary caller string.
   It must bind an opaque immutable epoch, configured music-root IDs and
   a complete admitted Bliss catalog snapshot (or an authenticated
   snapshot identifier maintained by the host). The manifest must be
   stable while scanning and have a precisely defined invalidation
   rule after any scan, catalog replacement or root reconfiguration.
2. **Portable root map**: each LMS root receives a unique stable root ID
   that survives an analyser running on a different machine; the
   scanner's local source path mapping is declared separately from
   that host root ID. Root physical paths are not stable identities
   across Windows, Linux, NAS mounts or Raspberry Pi hosts. A manifest
   records the exact host root ID and an unambiguous mapping used to
   decode each selected original audio file.
3. **Scanner receipt**: the offline analyser records, independently
   of the generic host, the verified host scan epoch, root-map digest,
   chosen track ID/root ID/relative key, model fingerprint, original
   audio SHA-256 and the scanner's guarded analysis-success status.
   Existing pre-guard SQLite-v3 rows cannot be upgraded merely by
   checking their current file hash: their decoded-source provenance
   remains unproven. A dedicated migration/new version or separately
   verified append-only receipt is needed.
4. **Provider admission**: before building an SPI-v2 resource, the
   Essentia Lyrion provider independently checks that the host's
   current epoch/root map matches the scanner receipt, the bounded
   host-admitted candidate cohort is complete, every root-relative
   key is unique and each model head has valid source freshness.
   Any missing evidence, root collision or changed epoch means
   **neutral/unavailable**, never optimistic fallback.
5. **Post-run recheck**: after the native SPI returns but before
   exposing even passive diagnostics, revalidate the authoritative
   host epoch. Avoid falsely attributing a snapshot to a newer
   catalog. Because the native provider remains `signals=[]`,
   this cannot modify the live ranking.

## No host-specific SPI extensions

The generic host continues to pass exactly the existing SPI v2
`artifacts`, `resources`, `anchors` and `candidates` envelope. Only
the Lyrion Essentia provider resolves source provenance and creates
its private resource bundle; the native Rust provider consumes it.
Do not add `Essentia*.pm` modules, database access or a separate native
subprocess to BlissMixerLab. No new SPI operation is proposed.

## Test matrix required before production

- Scan generation changes while one candidate pool is being admitted.
- Scan generation changes between feature export and native response.
- Same relative filename in two configured roots and overlapping/nested
  roots; distinguish actual physical recording and source root used
  during offline analysis.
- Scanner and host on different OS and differing root mount paths.
- Source audio changed during decode; pre-guard and post-guard feature
  rows mixed in the same SQLite-v3 database.
- Stale model fingerprint or missing host epoch / root mapping.
- Power loss/partial write, read-only storage, WAL concurrent writes and
  very large libraries without an unbounded database or full-audio copy.
- Failures must never change DSTM, queues or actual Bliss ranks.

## Currently available evidence

- [Offline source content proof](audio-content-provenance-20261031.md)
  matches original file SHA-256 across a limited cohort and two roots,
  with actual unchanged SPI v2 JSONL transport.
- [Scanner stability Draft PR #6](https://github.com/chrober/essentia-analyser/pull/6)
  adds a best-effort pre/post original-file hash guard before SQLite
  persistence. It is not yet merged and does not persist an epoch.

**Open decision**: which authoritative Lyrion host API/event can
provide an immutable catalog scan epoch? Until grounded in actual
Lyrion code or host behavior, the generation witness is not
considered implemented or trustworthy.
