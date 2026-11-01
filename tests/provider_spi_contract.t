use strict;
use warnings;
use Test::More;

{
    package StubPluginBase;
    sub initPlugin { 1 }

    package Slim::Plugin::Base;
    our @ISA = ('StubPluginBase');
    $INC{'Slim/Plugin/Base.pm'} = __FILE__;
    package main;
}

use lib '.';
require 'EssentiaGuidance/Provider.pm';
$INC{'Plugins/EssentiaGuidance/Provider.pm'} = $INC{'EssentiaGuidance/Provider.pm'};
require 'EssentiaGuidance/Plugin.pm';

my $descriptor = Plugins::EssentiaGuidance::Plugin->guidance_provider_descriptor_v1();
is($descriptor->{protocol_version}, 1, 'uses established Lyrion provider descriptor v1');
is($descriptor->{provider_id}, 'essentia', 'provider discovery identity is stable');
is($descriptor->{native_spi}{provider_id}, 'essentia-guidance',
    'native provider identity agrees with Rust SPI manifest');
is($descriptor->{native_spi}{spi_version}, 2, 'canonical SPI v2 only');
is($descriptor->{native_spi}{protocol}, 'bliss-guidance-jsonl-v2',
    'canonical native JSONL protocol');
is_deeply($descriptor->{scopes}, ['global_candidate'],
    'initial research channel is global only');
is_deeply($descriptor->{native_spi}{channels},
    { essentia_experimental_shadow => 'essentia_experimental_shadow' },
    'native shadow channel is declared without a host influence control');
is_deeply($descriptor->{native_spi}{artifact_kinds},
    ['essentia-exact-track-keys-v1'], 'existing native exact-key artifact type');
is_deeply($descriptor->{native_spi}{resource_kinds},
    ['essentia-feature-sqlite-v3'], 'existing native SQLite-v3 resource kind');
is_deeply($descriptor->{controls}, [], 'no premature influence or model UI controls');
is_deeply(Plugins::EssentiaGuidance::Plugin->guidance_provider_defaults_v1(),
    {settings_revision => 1}, 'no host-overridable signal weights exist');

my $status = Plugins::EssentiaGuidance::Plugin->guidance_provider_status_v1();
ok(!$status->{available}, 'provider remains unavailable even when discovered');
is($status->{reason}, 'source_generation_and_root_provenance_unverified',
    'missing authoritative generation/root witness is reported explicitly');

for my $payload (
    [undef, undef],
    [{enabled => 1}, {trusted => 1}],
    [{model_id => 'genre', metric => 'affine_cosine_v1'},
        {candidate_identity_artifact => {path => '/arbitrary/payload'}}],
) {
    my $allowed = eval {
        Plugins::EssentiaGuidance::Plugin->guidance_provider_native_spi_config_v1(@$payload);
        1;
    };
    ok(!$allowed, 'SPI native config fails closed even with caller-provided trust flags');
}

ok(Plugins::EssentiaGuidance::Plugin->can('guidance_provider_native_spi_config_v1'),
    'uses established provider method for future trusted SPI factory');
ok(!Plugins::EssentiaGuidance::Plugin->can('guidance_provider_acquire_artifacts_v1'),
    'does not introduce an alternative acquisition protocol');

done_testing;
