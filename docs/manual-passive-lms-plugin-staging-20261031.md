# Manual Essentia Guidance installation — staging only (31 October 2026)

**Status:** installable Lyrion plugin *shell* and manually invocable,
strictly passive **offline research probe**. No published release, no main
branch merge, no real Pi or production playback verification.

## Why separate installation from normal Guidance availability?

The existing Lyrion provider discovery contract treats
`guidance_provider_status_v1.available=1` as permission for the host to
request native scoring. Our Essentia data has no shared authoritative
scanner/Lyrion library generation witness, no approved real multi-root
source ownership and no validated General Metric.

We therefore **do not** change the normal provider status: it remains
`available=0` with reason
`source_generation_and_root_provenance_unverified`. The normal
`guidance_provider_native_spi_config_v1` always raises. Installing the
plugin never makes Essentia an available Guidance provider.

The settings page is **status-only**, with no preferences, arbitrary
path entry, experimental opt-in checkbox, active weight or probe button.
`install.xml` sets macOS, Windows and other platforms to **disabled**
by default. There is no library scan listener, scheduled job, remote
download, automatic native startup, release archive or plugin-repository
feed entry.

## Staging an isolated Lyrion instance

Use a separate Lyrion staging installation with its own config/cache
directories and playback ports. Never overwrite a plugin under the
production Pi's `Plugins` directory.

1. Check out the existing **research** branch
   `chrober/lms-guidance-essentia@feat/essentia-guidance-integration-design`
   and note its exact Git SHA.
2. Copy the **entire** `EssentiaGuidance/` directory, retaining
   `install.xml`, `Plugin.pm`, `Provider.pm`, `Settings.pm`,
   `strings.txt`, `HTML/`, `Bin/SOURCE.md` and the helper modules,
   into the isolated LMS installation as `Plugins/EssentiaGuidance/`.
   Do not copy the repository root as a single plugin.
3. Verify that the staging LMS plugin manager discovers
   `Plugins::EssentiaGuidance::Plugin` and lists it as **disabled** by
   default. Enable it only within the staging LMS if you want the
   status-only settings page and descriptor discovery check.
4. Confirm that the normal host shows provider `essentia` as
   **unavailable** and the settings page displays the source-provenance
   reason. No native process is started by installation or by loading
   this page.
5. Independently build the native
   `chrober/bliss-guidance-essentia` executable from a pinned,
   reviewed research commit for the staging architecture. Verify
   `version --json` gives `essentia-guidance` / SPI 2. Do not
   redistribute native binaries until the separate GPL/Essen­tia/ONNX
   dependency and licensing review is approved.

This staging workflow does **not** yet prove that the actual LMS
PluginManager can load the plugin in a full running server. Automated
tests stage the same install layout with stub LMS modules; real server
installation is a later explicit acceptance gate.

## Bounded manual passive test

The optional `Plugins::EssentiaGuidance::PassiveProbe::run()`
is intended **only for trusted local Perl code inside an explicitly
isolated test environment**, not for an HTTP endpoint or preference
value. It accepts the same verified original host-track objects as
`ImportedSidecarPilot.pm` and requires:

- Literal `research_only=1` **and** `passive_only=1`;
- One host seed object and **exactly one independently bound**
  generic SPI `host_anchors` entry (`seed-1` plus original
  `candidate_id` and 32-hex `lms_urlmd5`), and 2–50 already
  host-admitted candidate objects. Never select/drop candidates just
  to pass this gate.
- One canonical music root, immutable read-only Bliss and manually
  transferred SQLite-v3 sidecar, matching model ID, model fingerprint
  and original validation flag; a private writable scratch directory.
- An **explicit, trusted absolute** local `native_program` path to a
  review-pinned executable; `deadline_ms` from 100 to 10000.
- Availability of the existing generic
  `Plugins::BlissGuidance::Runtime::score_batch` from the corrected
  shared-host research branch. This module does **not** add its own
  JSONL subprocess implementation.

A representative **trusted in-process call** after looking up actual
Lyrion source objects and verifying paths is:

```perl
my ($anchors, $ids) =
    Plugins::BlissMixerLab::GuidanceProviderAdapter::build_seed_context(
        [$seed_track]);
die 'only a single research seed is supported' unless @$anchors == 1;

my $result = Plugins::EssentiaGuidance::PassiveProbe::run(
    research_only => 1,
    passive_only => 1,
    experimental_preview_opt_in => 1,
    directory => $isolated_private_scratch,
    bliss_db => $read_only_bliss_snapshot,
    feature_db => $manually_transferred_sqlite_v3,
    media_dirs => [$one_canonical_music_root],
    anchors => [$seed_track],
    host_anchors => $anchors,
    candidates => \@already_admitted_lms_tracks,
    model_id => 'genre',
    metric => 'affine_cosine_v1',
    expected_model_key => $inspected_exact_model_fingerprint,
    job_id => 'staging-probe-001',
    native_program => $pinned_local_native_executable,
    deadline_ms => 5000,
);
die 'research probe failed' unless $result->{valid};
die 'nonneutral probe not allowed' if @{$result->{signals}};
```

**All variables are intentionally supplied by trusted local test code**;
there is no browser, Lyrion CLI command or generic host API that
populates them automatically. Use a small, explicitly chosen real
Windows-analyzed cohort for the initial acceptance test; real audio
bytes are **not** hashed on the Pi by this lightweight pilot.

The probe invokes the *existing generic Guidance SPI v2 runtime*,
accepts only a completed `essentia-guidance` session with
`shadow_evaluated_no_active_signals` and `signals=[]`, and deletes
its private temporary identity artifact / bounded SQLite projection
after any outcome. Errors return a path-free neutral
`{valid=>0, signals=>[], state=>'passive_probe_failed'}`.
This is **not** a normal host/provider scoring configuration; that
factory remains unavailable even if a native executable exists.

## Proven by CI vs not yet demonstrated

- **CI:** install-layout and default-disabled semantics, status page
  and provider factory safety, explicit opt-in and deadline validation,
  manual-probe resource cleanup on success and failures, neutral
  result contract, read-only SQLite projection and a true generic
  Perl Host → native Rust SPI JSONL session against a synthetic
  Windows-to-Pi transfer fixture.
- **Still required:** a real running staging Lyrion installation,
  Lyrion `Slim::Schema::Track` fixture from a manually scanned
  subset, true Windows/Pi source-root mapping, ARM native build and
  CPU/RAM testing, portable native binary distribution and licensing
  review, and explicit real-host trusted acquisition/cleanup lifecycle
  for any future *normal* Guidance provider integration.

The intended next step is a real, strictly **passive staging-server
smoke test**, not a merge, native release, product activation or change
to the production Pi.
