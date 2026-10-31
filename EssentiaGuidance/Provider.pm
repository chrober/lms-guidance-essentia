package Plugins::EssentiaGuidance::Provider;

use strict;
use warnings;

# This is the normal Lyrion provider discovery facade, not an Essentia
# integration in a generic host. Deliberately unavailable until a trusted
# cross-database generation and root-qualified identity witness exists.
sub guidance_provider_descriptor_v1 {
    return {
        protocol_version => 1,
        provider_id => 'essentia',
        display_name => 'Bliss Guidance: Essentia (research)',
        capabilities => ['essentia_experimental_shadow'],
        scopes => ['global_candidate'],
        settings_schema_version => 1,
        controls => [],
        native_spi => {
            provider_id => 'essentia-guidance',
            spi_version => 2,
            protocol => 'bliss-guidance-jsonl-v2',
            channels => {
                essentia_experimental_shadow => 'essentia_experimental_shadow',
            },
            artifact_kinds => ['essentia-exact-track-keys-v1'],
            resource_kinds => ['essentia-feature-sqlite-v3'],
        },
    };
}

sub guidance_provider_defaults_v1 {
    return { settings_revision => 1 };
}

sub guidance_provider_status_v1 {
    # Even a manually installed native binary and a readable SQLite sidecar
    # cannot establish source generation or multiple-root provenance.
    # Never mark this plugin ready solely based on local file existence.
    return {
        available => 0,
        reason => 'source_generation_and_root_provenance_unverified',
    };
}

sub guidance_provider_native_spi_config_v1 {
    # No bypass through fabricated trusted_job_context or a host override.
    # A future integration must attest both source provenance and track keys
    # before returning exactly the descriptor-declared SPI resources.
    die 'Essentia provider unavailable: source provenance not verified';
}

1;
