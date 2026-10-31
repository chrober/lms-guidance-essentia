use strict;
use warnings;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use File::Spec;
use FindBin;
use IPC::Open3 qw(open3);
use JSON::PP qw(encode_json decode_json);
use Symbol qw(gensym);
use Test::More;

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'SQLite Perl driver not installed';
}
my $binary = $ENV{ESSENTIA_NATIVE_SPI_BIN} || '';
plan skip_all => 'native binary not configured for optional CI check'
    unless $binary && -f $binary && -x $binary;

{
    package SpiWireTrack;
    sub new { bless { url => $_[1], path => $_[2] }, $_[0] }
    sub url { $_[0]->{url} }
    sub path { $_[0]->{path} }
}

use lib "$FindBin::Bin/..";
require 'EssentiaGuidance/SpiResourceBundle.pm';
require 'EssentiaGuidance/Provider.pm';

my $dir = tempdir(CLEANUP => 1);
my $root_a = File::Spec->catdir($dir, 'music_a');
my $root_b = File::Spec->catdir($dir, 'music_b');
mkdir($root_a) or die $!;
mkdir($root_b) or die $!;
my $bliss_path = File::Spec->catfile($dir, 'bliss.db');
my $features_path = File::Spec->catfile($dir, 'features.db');
my $bliss = DBI->connect("dbi:SQLite:dbname=$bliss_path", '', '', {RaiseError=>1});
my $features = DBI->connect("dbi:SQLite:dbname=$features_path", '', '', {RaiseError=>1});
$bliss->do('CREATE TABLE TracksV2(File TEXT NOT NULL, Ignore INTEGER)');
$features->do('PRAGMA user_version=3');
$features->do(q{CREATE TABLE feature_models(
    model_key TEXT PRIMARY KEY, preprocessing_version TEXT, aggregation TEXT,
    classes_json TEXT, validated_against_essentia INTEGER)});
$features->do(q{CREATE TABLE feature_tracks(
    track_file TEXT, model_id TEXT, capability TEXT, audio_sha256 TEXT,
    model_key TEXT, scores_f32_le BLOB, PRIMARY KEY(track_file,model_id))});
$features->do(q{CREATE TABLE feature_track_state(
    track_file TEXT, model_id TEXT, file_size INTEGER, modified_ns INTEGER,
    model_key TEXT, PRIMARY KEY(track_file,model_id))});
$features->do('INSERT INTO feature_models VALUES(?,?,?,?,1)', undef,
    'model-pin', 'preprocessing-v1', 'mean',
    encode_json([map { "class$_" } 0..86]));
my @names = qw(seed one two);
my @actual_paths;
for my $name (@names) {
    my $actual_root = $name eq 'two' ? $root_b : $root_a;
    my $audio_path = File::Spec->catfile($actual_root, "$name.flac");
    my $raw_audio = "Synthetic source bytes for $name / provider SPI fixture";
    open my $source_fh, '>:raw', $audio_path or die $!;
    print {$source_fh} $raw_audio or die $!;
    close($source_fh) or die $!;
    push @actual_paths, $audio_path;
    $bliss->do('INSERT INTO TracksV2 VALUES (?,0)', undef, "$name.flac");
    my $vector = pack('f<*', map {
        0.05 + ((($_ * 17 + length($name) * 3) % 85) / 100)
    } 0..86);
    my $insert = $features->prepare('INSERT INTO feature_tracks VALUES(?,?,?,?,?,?)');
    $insert->bind_param(1, "$name.flac");
    $insert->bind_param(2, 'genre');
    $insert->bind_param(3, 'genre');
    $insert->bind_param(4, sha256_hex($raw_audio));
    $insert->bind_param(5, 'model-pin');
    $insert->bind_param(6, $vector, DBI::SQL_BLOB());
    $insert->execute;
    $insert->finish;
    $features->do('INSERT INTO feature_track_state VALUES(?,?,?,?,?)', undef,
        "$name.flac", 'genre', length($raw_audio), 0, 'model-pin');
}
$bliss->disconnect;
$features->disconnect;
my @tracks = map {
    SpiWireTrack->new("file:///test/$_" . '.flac', $actual_paths[$_])
} 0..$#names;
my $bundle = Plugins::EssentiaGuidance::SpiResourceBundle::assemble_research_bundle(
    research_only => 1, verify_audio_content => 1, directory => $dir,
    bliss_db => $bliss_path, feature_db => $features_path,
    media_dirs => [$root_a, $root_b],
    catalog_roots => [
        {root_id => 'host-root-a', host_path => $root_a},
        {root_id => 'host-root-b', host_path => $root_b},
    ],
    anchors => [$tracks[0]], candidates => [@tracks[1,2]],
    model_id => 'genre', metric => 'affine_cosine_v1',
    expected_model_key => 'model-pin', job_id => 'native-fixture-job',
);
is($bundle->{catalog_fingerprint}{eligible_tracks}, 3,
    'provider verified full host-admitted Bliss catalog before native prepare');
like($bundle->{catalog_fingerprint}{fingerprint_sha256},
    qr/\A[a-f0-9]{64}\z/, 'catalog and root map fingerprint bound to bundle');
ok(!$bundle->{catalog_fingerprint}{generation_verified},
    'no synthetic Lyrion generation attestation is fabricated');
is($bundle->{audio_content_audit}{verified_count}, 3,
    'native bundle attests all original audio bytes against scanner SHA256');
is($bundle->{audio_content_audit}{music_root_count}, 2,
    'native bundle supports two distinct, collision-free physical music roots');
ok(!$bundle->{audio_content_audit}{generation_verified},
    'content proof does not masquerade as a joint library generation');

# Test-only process driver: the production Lyrion host still invokes this
# binary exclusively through the shared Guidance SPI native host.
my @requests = (
    { type => 'describe', spi_version => 2 },
    {
        type => 'prepare', spi_version => 2,
        job_id => $bundle->{job_id},
        options => $bundle->{options},
        artifacts => $bundle->{artifacts},
        resources => $bundle->{resources},
        # Canonical Anchor uses #[serde(flatten)] Candidate, never a nested
        # `track` object. Keep the exact provider-owned SPI envelope.
        anchors => $bundle->{anchors},
    },
    {
        type => 'score', spi_version => 2,
        request_id => 'research-cohort',
        context => $bundle->{context},
        candidates => $bundle->{candidates},
    },
    { type => 'close', spi_version => 2 },
);

my $err = gensym();
my ($in, $out);
my $pid = open3($in, $out, $err, $binary);
binmode($in, ':raw');
binmode($out, ':raw');
for my $request (@requests) {
    print {$in} encode_json($request) . "\n"
        or die 'could not write native SPI fixture';
}
close($in);
my @responses = <$out>;
my $stderr = do { local $/; <$err> };
close($out);
close($err);
waitpid($pid, 0);
is($? >> 8, 0, 'real independent native SPI v2 process exited successfully');
is($stderr, '', 'native provider emits no private data to stderr');
is(scalar(@responses), 4, 'actual describe/prepare/score/close exchanges completed');
my @replies = map { decode_json($_) } @responses;
is($replies[0]{type}, 'manifest', 'native provider emitted canonical manifest');
is($replies[0]{provider_id}, 'essentia-guidance',
    'manifest matches Lyrion discovery facade');
diag('native prepare code=' . ($replies[1]{code} || '<none>')) unless $replies[1]{type} eq 'prepared';
is($replies[1]{type}, 'prepared', 'native SPI accepted provider-owned artifact and projected resource');
is($replies[2]{type}, 'scores', 'native SPI accepted exact complete global candidate batch');
diag('native score state=' . ($replies[2]{diagnostics}{state} || '<none>')
     . ' reason=' . ($replies[2]{diagnostics}{details}{reason} || '<none>'))
    unless ($replies[2]{diagnostics}{state} || '') eq 'shadow_evaluated_no_active_signals';
is($replies[2]{diagnostics}{state}, 'shadow_evaluated_no_active_signals',
    'geometry was evaluated without active guidance');
is_deeply($replies[2]{signals}, [], 'no live candidate influence possible');
is($replies[3]{type}, 'closed', 'native SPI session closes without a side channel');
my $output = join('', @responses);
unlike($output, qr/file:\/\/|\/music\/|model-pin|\.flac/,
    'native response discloses no private file IDs or source paths');
ok(!Plugins::EssentiaGuidance::Provider::guidance_provider_status_v1()->{available},
    'test-only exchange does not activate actual Lyrion provider');

# Reopen after a separate catalog update: original admission cannot be
# misrepresented as still current, even though the native SPI succeeded.
my $writer = DBI->connect("dbi:SQLite:dbname=$bliss_path", '', '',
    {RaiseError => 1, AutoCommit => 1});
$writer->do('INSERT INTO TracksV2 VALUES (?,0)', undef, 'late-catalog-entry.flac');
$writer->disconnect;
require 'EssentiaGuidance/CatalogFingerprint.pm';
my $post_run = eval {
    Plugins::EssentiaGuidance::CatalogFingerprint::assert_fresh(
        research_only => 1, bliss_db => $bliss_path,
        roots => [
            {root_id => 'host-root-a', host_path => $root_a},
            {root_id => 'host-root-b', host_path => $root_b},
        ],
        expected => {
            kind => $bundle->{catalog_fingerprint}{kind},
            fingerprint_sha256 => $bundle->{catalog_fingerprint}{fingerprint_sha256},
            catalog_sha256 => '0' x 64,
            host_root_map_sha256 => '0' x 64,
            eligible_tracks => 3,
        },
    );
    1;
};
ok(!$post_run, 'subsequent catalog change invalidates stored admission fingerprint');

done_testing();
