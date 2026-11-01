use strict;
use warnings;
use Config qw(%Config);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

use lib "$FindBin::Bin/..";
require 'EssentiaGuidance/PassiveProbe.pm';

my $scratch = tempdir(CLEANUP => 1);
my $program = $Config{perlpath};
ok(-x $program && File::Spec->file_name_is_absolute($program),
    'fixture uses a local executable and never fetches a binary');

my ($built_private, $host_config, $host_request, $simulated);
{
    no warnings 'redefine';
    *Plugins::EssentiaGuidance::ImportedSidecarPilot::assemble_pilot_bundle = sub {
        my %args = @_;
        my $directory = tempdir('probe-private-XXXXXX',
            DIR => $scratch, CLEANUP => 0);
        $built_private = $directory;
        my $resource = File::Spec->catfile($directory, 'bounded.sqlite');
        open my $fh, '>', $resource or die $!;
        print {$fh} 'fixture';
        close $fh;
        return {
            private_directory => $directory,
            job_id => 'offline-only',
            options => {experimental_preview_opt_in => 1},
            artifacts => [{kind => 'essentia-exact-track-keys-v1',
                path => File::Spec->catfile($directory, 'identity.json'),
                sha256 => ('a' x 64)}],
            resources => [{kind => 'essentia-feature-sqlite-v3',
                path => $resource, access => 'read_only'}],
            anchors => [{anchor_id => 'seed-1',
                candidate_id => 'file:///fixture/seed.flac'}],
            context => {scope => 'global',
                context_track_ids => ['seed-1'],
                left_anchor_id => undef, right_anchor_id => undef},
            candidates => [
                {candidate_id => 'file:///fixture/a.flac'},
                {candidate_id => 'file:///fixture/b.flac'},
            ],
            audit => {model_status => 'experimental',
                host_route_bound => 1},
        };
    };
}
{
    package Plugins::BlissGuidance::Runtime;
    our $scenario = 'success';
    sub score_batch {
        ($main::host_config, $main::host_request) = @_;
        return {
            valid => 1,
            signals => $scenario eq 'active_signals' ? [{candidate_id => 'forbidden'}] : [],
            manifest => {provider_id => $scenario eq 'wrong_provider'
                ? 'unknown' : 'essentia-guidance'},
            prepared => {type => 'prepared'},
            diagnostics => {state => $scenario eq 'wrong_state'
                ? 'unverified' : 'shadow_evaluated_no_active_signals'},
        } unless $scenario eq 'failed_host';
        return {valid => 0, diagnostic => '/private/audio/title.flac', signals => []};
    }
    $INC{'Plugins/BlissGuidance/Runtime.pm'} = __FILE__;
}
# Allow main-scoped test variables to be assigned by the stub package.
{
    no warnings 'once';
    *main::host_config = \$host_config;
    *main::host_request = \$host_request;
}
my %args = (
    research_only => 1, passive_only => 1,
    host_anchors => [{anchor_id => 'seed-1'}],
    native_program => $program,
    directory => $scratch,
    deadline_ms => 1000,
);
my $probe = sub {
    my $result = Plugins::EssentiaGuidance::PassiveProbe::run(%args, @_);
    ok(!-e $built_private, 'private bounded resource and identity artifact always removed')
        if defined $built_private;
    return $result;
};
my $success = $probe->();
ok($success->{valid}, 'explicit local passive host probe accepts a completed neutral session');
is_deeply($success->{signals}, [], 'offline host cannot emit playlist influence');
is($success->{state}, 'shadow_evaluated_no_active_signals', 'only native shadow state accepted');
is($success->{candidate_count}, 2, 'admitted candidate count is bounded');
is($success->{model_status}, 'experimental', 'original model validation status retained');
ok($success->{host_route_bound}, 'host-route audit retained without claiming audio parity');
ok(!$success->{source_bytes_verified} && !$success->{catalog_generation_verified},
    'successful shadow test never claims content parity or source-generation proof');
is($host_config->{id}, 'essentia-guidance', 'generic host receives exact descriptor provider ID');
is($host_request->{anchors}[0]{anchor_id}, 'seed-1',
    'shared SPI runtime receives verified original Lab seed route token');
is_deeply([map { $_->{candidate_id} } @{$host_request->{candidates}}],
    ['file:///fixture/a.flac', 'file:///fixture/b.flac'],
    'host sees only admitted candidates without reordering');

for my $scenario (qw(active_signals wrong_provider wrong_state failed_host)) {
    local $Plugins::BlissGuidance::Runtime::scenario = $scenario;
    my $res = $probe->();
    ok(!$res->{valid}, "native failure $scenario is neutral and fail-closed");
    is_deeply($res->{signals}, [], "native failure $scenario never exposes signals");
    ok(!exists $res->{diagnostic},
        'source paths, native errors and identities are not exposed in probe results');
}
for my $overrides (
    {research_only => 0}, {passive_only => 0},
    {host_anchors => []}, {host_anchors => undef},
    {native_program => File::Spec->catfile($scratch, 'missing-binary')},
    {deadline_ms => 0}, {deadline_ms => 10001},
) {
    my $accepted = eval {
        Plugins::EssentiaGuidance::PassiveProbe::run(%args, %$overrides); 1;
    };
    ok(!$accepted, 'manual probe cannot bypass explicit trust and time bounds');
}

done_testing();
