use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON::PP qw(encode_json decode_json);
use Test::More;

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'SQLite Perl driver required';
}
{
    package ImportedPiTrack;
    sub new { bless {url => $_[1], path => $_[2], urlmd5 => $_[3]}, $_[0] }
    sub url { $_[0]->{url} }
    sub path { $_[0]->{path} }
    sub urlmd5 { $_[0]->{urlmd5} }
}
use lib "$FindBin::Bin/..";
require 'EssentiaGuidance/ImportedSidecarPilot.pm';
require 'EssentiaGuidance/Provider.pm';

sub db {
    my $p = shift;
    DBI->connect("dbi:SQLite:dbname=$p", '', '',
        {RaiseError => 1, PrintError => 0, AutoCommit => 1});
}
my $dir = tempdir(CLEANUP => 1);
my $root = File::Spec->catdir($dir, 'pi-music');
make_path($root);
my $bliss_file = File::Spec->catfile($dir, 'pi-bliss.sqlite');
my $win_file = File::Spec->catfile($dir, 'windows-sidecar.sqlite');
my $pi_file = File::Spec->catfile($dir, 'pi-imported-features.sqlite');
my $bliss = db($bliss_file);
$bliss->do('CREATE TABLE TracksV2(File TEXT NOT NULL, Ignore INTEGER)');
my $win = db($win_file);
$win->do('PRAGMA user_version=3');
$win->do(q{CREATE TABLE feature_models(
    model_key TEXT PRIMARY KEY, preprocessing_version TEXT, aggregation TEXT,
    classes_json TEXT, validated_against_essentia INTEGER)});
$win->do(q{CREATE TABLE feature_tracks(
    track_file TEXT, model_id TEXT, capability TEXT, audio_sha256 TEXT,
    model_key TEXT, scores_f32_le BLOB, PRIMARY KEY(track_file,model_id))});
$win->do(q{CREATE TABLE feature_track_state(
    track_file TEXT, model_id TEXT, file_size INTEGER, modified_ns INTEGER,
    model_key TEXT, PRIMARY KEY(track_file,model_id))});
$win->do('INSERT INTO feature_models VALUES(?,?,?,?,0)', undef,
    'real-windows-unvalidated-model', 'v1', 'mean',
    encode_json([map { "genre$_" } 0..86]));
my @names = qw(seed.flac one.flac two.flac);
my @paths;
my @host_tracks;
for my $i (0..$#names) {
    my $name = $names[$i];
    my $full = File::Spec->catfile($root, $name);
    open my $audio, '>:raw', $full or die $!;
    my $bytes = "Audio from Windows NAS / real Pi filename $name";
    print {$audio} $bytes or die $!;
    close $audio or die $!;
    push @paths, $full;
    push @host_tracks, ImportedPiTrack->new(
        "file:///host/$name", $full, sprintf('%032x', $i + 1));
    $bliss->do('INSERT INTO TracksV2 VALUES (?,0)', undef, $name);
    my $stmt = $win->prepare('INSERT INTO feature_tracks VALUES(?,?,?,?,?,?)');
    $stmt->bind_param(1, $name);
    $stmt->bind_param(2, 'genre');
    $stmt->bind_param(3, 'genre');
    $stmt->bind_param(4, sha256_hex($bytes));
    $stmt->bind_param(5, 'real-windows-unvalidated-model');
    $stmt->bind_param(6, pack('f<*', map { 0.02 + (($i + $_) % 88) / 100 } 0..86), DBI::SQL_BLOB());
    $stmt->execute;
    $stmt->finish;
    $win->do('INSERT INTO feature_track_state VALUES(?,?,?,?,?)', undef,
        $name, 'genre', length($bytes), 0, 'real-windows-unvalidated-model');
}
$bliss->do('INSERT INTO TracksV2 VALUES (?,0)', undef, 'unanalysed.flac');
# Exists physically and in Bliss, but intentionally has NO imported feature row.
my $missing_file = File::Spec->catfile($root, 'unanalysed.flac');
open my $missing_audio, '>:raw', $missing_file or die $!;
print {$missing_audio} 'Physical Pi track not present in manual Windows export' or die $!;
close $missing_audio or die $!;
$bliss->disconnect;
$win->disconnect;
copy($win_file, $pi_file) or die 'manual Windows SQLite export fixture copy failed';

# Reuse the REAL generic Lab helper when the pinned research checkout is
# available in CI. The small local fixture below preserves identical
# inputs for standalone read-only unit tests without another checkout.
my $lab_adapter = $ENV{ESSENTIA_LAB_ADAPTER_SRC} || '';
my $host_seed_anchors;
if (length($lab_adapter)) {
    my $path = File::Spec->catfile(
        $lab_adapter, 'BlissMixerLab', 'GuidanceProviderAdapter.pm');
    die 'pinned generic Lab seed adapter unavailable' unless -f $path;
    require $path;
    my ($anchors, $context_ids) =
        Plugins::BlissMixerLab::GuidanceProviderAdapter::build_seed_context(
            [$host_tracks[0]]);
    die 'generic Lab host did not supply exactly one stable source seed'
        unless ref($anchors) eq 'ARRAY' && @$anchors == 1
            && ref($context_ids) eq 'ARRAY'
            && @$context_ids == 1 && $context_ids->[0] eq 'seed-1';
    $host_seed_anchors = $anchors;
} else {
    $host_seed_anchors = [{
        anchor_id => 'seed-1',
        candidate_id => $host_tracks[0]->url,
        lms_urlmd5 => $host_tracks[0]->urlmd5,
    }];
}

my %args = (
    research_only => 1, passive_only => 1,
    experimental_preview_opt_in => 1,
    directory => $dir,
    bliss_db => $bliss_file, feature_db => $pi_file,
    media_dirs => [$root],
    anchors => [$host_tracks[0]],
    host_anchors => $host_seed_anchors,
    candidates => [@host_tracks[1,2]],
    model_id => 'genre', metric => 'affine_cosine_v1',
    expected_model_key => 'real-windows-unvalidated-model',
    job_id => 'imported-pi-pilot',
);
my $build = sub {
    my (%override) = @_;
    Plugins::EssentiaGuidance::ImportedSidecarPilot::assemble_pilot_bundle(
        %args, %override);
};
my $bundle = $build->();
is($bundle->{audit}{admitted_tracks}, 3, 'three actual Pi filenames matched Windows import');
is($bundle->{audit}{model_status}, 'experimental',
    'unvalidated Windows model status retained without mislabelling');
ok(!$bundle->{audit}{source_bytes_verified}, 'never claims to hash audio on Pi');
ok(!$bundle->{audit}{catalog_generation_verified}, 'no fabricated shared LMS scan generation');
ok(!$bundle->{audit}{full_catalog_verified}, 'partial cohort does not require 65k complete catalog');
ok($bundle->{passive_only}, 'bundle is explicitly marked passive-only');
ok($bundle->{options}{experimental_preview_opt_in}, 'native SPI receives explicit experimental preview flag');
is($bundle->{resources}[0]{access}, 'read_only', 'only immutable SPI resource descriptor');
ok(-r $bundle->{resources}[0]{path}, 'projected private sidecar is readable');
ok(-s $bundle->{resources}[0]{path} < 4*1024*1024, 'bounded cohort SQLite is less than 4 MiB');
like($bundle->{artifacts}[0]{sha256}, qr/\A[a-f0-9]{64}\z/, 'exact-key artifact SHA is pinned');
is_deeply([map { $_->{candidate_id} } @{$bundle->{candidates}}],
    [map { $_->url } @host_tracks[1,2]], 'existing admitted candidate IDs retain order');
my $read = db($bundle->{resources}[0]{path});
is($read->selectrow_array('SELECT count(*) FROM feature_tracks'), 3,
    'unrelated or missing catalogue rows never included in SPI resource');
is($read->selectrow_array('SELECT validated_against_essentia FROM feature_models'), 0,
    'native sidecar still encodes true unvalidated model status');
$read->disconnect;
my $artifact;
{
    open my $fh, '<:raw', $bundle->{artifacts}[0]{path} or die $!;
    local $/; $artifact = decode_json(<$fh>); close $fh;
}
is_deeply([map { $_->{track_file} } @{$artifact->{tracks}}], \@names,
    'cross-machine source keys are root-relative, exact, ordered and distinct');
is_deeply([map { $_->{track_id} } @{$artifact->{tracks}}],
    ['seed-1', map { $_->url } @host_tracks[1,2]],
    'native exact-key artifact now binds generic host seed-N without relabeling candidates');
is($bundle->{anchors}[0]{anchor_id}, 'seed-1',
    'prepare uses the unchanged generic Last.fm-style route token');
is($bundle->{anchors}[0]{candidate_id}, $host_tracks[0]->url,
    'host anchor retains source file URL independent of its route token');
is($bundle->{anchors}[0]{lms_urlmd5}, $host_tracks[0]->urlmd5,
    'host anchor retains the verified original Lyrion hash');
is_deeply($bundle->{context}{context_track_ids}, ['seed-1'],
    'score references precisely the same verified generic seed token');
ok($bundle->{audit}{host_route_bound},
    'local research audit distinguishes an explicitly bound host route');
my $unaliased = $build->(host_anchors => undef);
is($unaliased->{anchors}[0]{anchor_id}, $host_tracks[0]->url,
    'original direct offline research API remains backward compatible');
ok(!$unaliased->{audit}{host_route_bound},
    'direct offline API does not claim that an opaque host route was verified');
ok(!Plugins::EssentiaGuidance::Provider::guidance_provider_status_v1()->{available},
    'offline imported pilot cannot enable the real LMS provider');

my @negative = (
    [{ research_only => 0 }, 'cannot execute without explicit offline research opt-in'],
    [{ host_anchors => [] }, 'empty generic route set is not a one-seed binding'],
    [{ host_anchors => [{ %{$host_seed_anchors->[0]}, anchor_id => 'seed-2',
          candidate_id => $host_tracks[1]->url }] },
      'a route token cannot bind a different Lyrion song URL'],
    [{ host_anchors => [{ %{$host_seed_anchors->[0]}, lms_urlmd5 => 'f' x 32 }] },
      'a forged Lyrion hash cannot acquire a trusted source key'],
    [{ host_anchors => [{ %{$host_seed_anchors->[0]}, anchor_id => 'seed-0' }] },
      'invalid generic seed numbering fails before native prepare'],
    [{ passive_only => 0 }, 'cannot be used to produce active guidance'],
    [{ experimental_preview_opt_in => 0 }, 'unvalidated model rejected without preview opt-in'],
    [{ expected_model_key => 'wrong-pin' }, 'mismatched ONNX model fingerprint is rejected'],
    [{ media_dirs => [$root, $dir] }, 'multi-root v3 source keys remain ambiguous'],
    [{ candidates => [$host_tracks[1], $host_tracks[1]] }, 'duplicate candidate IDs fail closed'],
    [{ candidates => [$host_tracks[1], ImportedPiTrack->new('file:///host/unanalysed.flac', File::Spec->catfile($root, 'unanalysed.flac'))] },
      'unanalysed host candidate forces whole-batch fallback'],
);
for my $case (@negative) {
    my ($override, $why) = @$case;
    my $ok = eval { $build->(%$override); 1 };
    ok(!$ok, $why);
}

my $old = -s $paths[1];
open my $changed, '>>:raw', $paths[1] or die $!;
print {$changed} ' extra bytes' or die $!;
close $changed;
my $stale_size = eval { $build->(); 1 };
ok(!$stale_size, 'different Pi audio file size fails imported feature cohort');
truncate($paths[1], $old) or die $!;

# Supplemental real native SPI test, using the same existing host JSONL
# protocol and *no* external audio decoder. Optional for pure Perl runs.
my $native = $ENV{ESSENTIA_NATIVE_SPI_BIN} || '';
SKIP: {
    skip 'independent Rust native SPI not configured', 10
        unless $native && -x $native;
    require IPC::Open3;
    require Symbol;
    my @requests = (
        {type => 'describe', spi_version => 2},
        {type => 'prepare', spi_version => 2,
            job_id => $bundle->{job_id},
            options => $bundle->{options},
            artifacts => $bundle->{artifacts},
            resources => $bundle->{resources},
            anchors => $bundle->{anchors},
        },
        {type => 'score', spi_version => 2,
            request_id => 'manual-windows-import',
            context => $bundle->{context},
            candidates => $bundle->{candidates},
        },
        {type => 'close', spi_version => 2},
    );
    my $err = Symbol::gensym();
    my ($in, $out);
    my $pid = IPC::Open3::open3($in, $out, $err, $native);
    for my $request (@requests) { print {$in} encode_json($request)."\n" or die $!; }
    close $in;
    my @reply_lines = <$out>;
    my $stderr = do { local $/; <$err> };
    close $out; close $err;
    waitpid($pid, 0);
    my @reply = map { decode_json($_) } @reply_lines;
    is($? >> 8, 0, 'real native provider exits cleanly on Windows-sidecar import');
    is($stderr, '', 'no original audio, personal IDs or file paths printed to stderr');
    is(scalar(@reply), 4, 'all four existing SPI v2 phases completed');
    is($reply[0]{type}, 'manifest', 'existing native provider manifests same SPI');
    is($reply[1]{type}, 'prepared', 'existing native provider accepted Windows experimental SQLite feature subset');
    is($reply[2]{type}, 'scores', 'existing native provider scored read-only imported features');
    is($reply[2]{diagnostics}{state}, 'shadow_evaluated_no_active_signals',
        'experimental geometry was evaluated only with explicit preview opt-in');
    is_deeply($reply[2]{signals}, [], 'no playlist scoring influence possible');
    is($reply[3]{type}, 'closed', 'native provider closes correctly');
    unlike(join('', @reply_lines), qr/\.flac|pi-music|Windows NAS|file:\/\//,
        'native replies contain no private source paths or track keys');
}


# Additional cross-repository gate: the actual GENERIC Perl host runtime
# must carry the same trusted seed and candidate IDs to the independent
# native Essentia JSONL provider. Host and native revisions are CI pinned.
# This is NOT an active Lab/DSTM call or Lyrion plugin deployment.
my $host_source = $ENV{ESSENTIA_SHARED_HOST_SRC} || '';
SKIP: {
    skip 'pinned shared host + independent native provider not available', 8
        unless $host_source && -f File::Spec->catfile($host_source,
            'Plugins', 'BlissGuidance', 'Runtime.pm')
            && $native && -x $native;
    require File::Spec;
    require File::Basename;
    my $runtime = File::Spec->catfile(
        $host_source, 'Plugins', 'BlissGuidance', 'Runtime.pm');
    require $runtime;
    my $config = {
        id => 'essentia-guidance',
        program => $native,
        options => $bundle->{options},
        artifacts => $bundle->{artifacts},
        resources => $bundle->{resources},
        timeout_ms => 5000,
    };
    my $request = {
        job_id => $bundle->{job_id},
        request_id => 'host-imported-sidecar-cohort',
        deadline_ms => 5000,
        anchors => $bundle->{anchors},
        context => $bundle->{context},
        candidates => $bundle->{candidates},
    };
    my $result = Plugins::BlissGuidance::Runtime::score_batch(
        $config, $request);
    diag('shared host native integration: ' . ($result->{diagnostic} || ''))
        unless $result->{valid};
    ok($result->{valid},
        'real generic host and real native Rust provider complete a full SPI-v2 exchange');
    is($result->{manifest}{provider_id}, 'essentia-guidance',
        'generic host negotiated the pinned Essentia native provider');
    is($result->{prepared}{type}, 'prepared',
        'prepare succeeded using exactly the provider-owned pinned seed');
    is($result->{diagnostics}{state},
        'shadow_evaluated_no_active_signals',
        'native geometry evaluated in the correct global seed context');
    is_deeply($result->{signals}, [],
        'full generic host integration remains strictly neutral');
    my $without_seed = Plugins::BlissGuidance::Runtime::score_batch(
        $config, { %$request, anchors => [] });
    ok(!$without_seed->{valid},
        'same provider fails closed if generic host loses the seed anchor');
    is_deeply($without_seed->{signals}, [],
        'missing seed never changes candidate ranking');
    my $fake_anchor = { %{$bundle->{anchors}[0]}, anchor_id => 'seed-2' };
    my $misaligned = Plugins::BlissGuidance::Runtime::score_batch(
        $config, { %$request, anchors => [$fake_anchor] });
    ok(!$misaligned->{valid},
        'synthetic seed-1 is not silently substituted for the pinned exact track ID');
}

done_testing();
