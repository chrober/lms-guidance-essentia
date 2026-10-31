use strict;
use warnings;
use File::Temp qw(tempdir);
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
    track_file TEXT, model_id TEXT, capability TEXT, model_key TEXT,
    scores_f32_le BLOB, PRIMARY KEY(track_file,model_id))});
$features->do('INSERT INTO feature_models VALUES(?,?,?,?,1)', undef,
    'model-pin', 'preprocessing-v1', 'mean',
    encode_json([map { "class$_" } 0..86]));
my @names = qw(seed one two);
for my $name (@names) {
    $bliss->do('INSERT INTO TracksV2 VALUES (?,0)', undef, "$name.flac");
    my $vector = pack('f<*', map {
        0.05 + ((($_ * 17 + length($name) * 3) % 85) / 100)
    } 0..86);
    my $insert = $features->prepare('INSERT INTO feature_tracks VALUES(?,?,?,?,?)');
    $insert->bind_param(1, "$name.flac");
    $insert->bind_param(2, 'genre');
    $insert->bind_param(3, 'genre');
    $insert->bind_param(4, 'model-pin');
    $insert->bind_param(5, $vector, DBI::SQL_BLOB());
    $insert->execute;
    $insert->finish;
}
$bliss->disconnect;
$features->disconnect;
my @tracks = map {
    SpiWireTrack->new("file:///music/$_.flac", "/music/$_.flac")
} @names;
my $bundle = Plugins::EssentiaGuidance::SpiResourceBundle::assemble_research_bundle(
    research_only => 1, directory => $dir,
    bliss_db => $bliss_path, feature_db => $features_path,
    media_dirs => ['/music'],
    anchors => [$tracks[0]], candidates => [@tracks[1,2]],
    model_id => 'genre', metric => 'affine_cosine_v1',
    expected_model_key => 'model-pin', job_id => 'native-fixture-job',
);

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

done_testing();
