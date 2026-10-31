use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON::PP ();
use Test::More;

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'DBD::SQLite unavailable';
}

{
    package SpiFixtureTrack;
    sub new { bless { url => $_[1], path => $_[2] }, $_[0] }
    sub url { $_[0]->{url} }
    sub path { $_[0]->{path} }
}
use lib "$FindBin::Bin/..";
require 'EssentiaGuidance/Provider.pm';
require 'EssentiaGuidance/ExactIdentity.pm';
require 'EssentiaGuidance/BoundedSnapshot.pm';
require 'EssentiaGuidance/SpiResourceBundle.pm';

sub db {
    my ($path) = @_;
    return DBI->connect("dbi:SQLite:dbname=$path", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1, sqlite_unicode => 1,
    });
}

my $dir = tempdir(CLEANUP => 1);
my $bliss_path = File::Spec->catfile($dir, 'bliss.sqlite');
my $feature_path = File::Spec->catfile($dir, 'features.sqlite');
my $bliss = db($bliss_path);
$bliss->do('CREATE TABLE TracksV2(File TEXT NOT NULL, Ignore INTEGER)');
my $feature = db($feature_path);
$feature->do('PRAGMA user_version = 3');
$feature->do(q{CREATE TABLE feature_models(
    model_key TEXT PRIMARY KEY, preprocessing_version TEXT, aggregation TEXT,
    classes_json TEXT, validated_against_essentia INTEGER)});
$feature->do(q{CREATE TABLE feature_tracks(
    track_file TEXT, model_id TEXT, capability TEXT, model_key TEXT,
    scores_f32_le BLOB, PRIMARY KEY(track_file, model_id))});
my $labels = JSON::PP->new->encode([map { "genre$_" } 0..86]);
$feature->do('INSERT INTO feature_models VALUES(?,?,?,?,?)', undef,
    'pinned-genre', 'preprocessing-v1', 'mean', $labels, 1);
my @keys = ('seed.flac', 'candidate-one.flac', 'candidate-two.flac');
my $insert = $feature->prepare('INSERT INTO feature_tracks VALUES(?,?,?,?,?)');
for my $key (@keys, 'unrelated.flac') {
    $bliss->do('INSERT INTO TracksV2 VALUES (?,0)', undef, $key);
    $insert->bind_param(1, $key);
    $insert->bind_param(2, 'genre');
    $insert->bind_param(3, 'genre');
    $insert->bind_param(4, 'pinned-genre');
    $insert->bind_param(5, pack('f<*', (0.25) x 87), DBI::SQL_BLOB());
    $insert->execute;
}
$insert->finish;
$bliss->disconnect;
$feature->disconnect;

my @items = map {
    SpiFixtureTrack->new("file:///music/$_", "/music/$_")
} @keys;
my %args = (
    research_only => 1, directory => $dir,
    bliss_db => $bliss_path, feature_db => $feature_path,
    media_dirs => ['/music'],
    anchors => [$items[0]], candidates => [@items[1,2]],
    model_id => 'genre', metric => 'affine_cosine_v1',
    expected_model_key => 'pinned-genre', job_id => 'offline-spi-proof',
);
my $bundle = Plugins::EssentiaGuidance::SpiResourceBundle::assemble_research_bundle(%args);
ok(-d $bundle->{private_directory}, 'caller-owned sealed staging directory exists');
ok(-f $bundle->{resources}[0]{path}, 'bounded SQLite v3 resource exists');
is($bundle->{resources}[0]{kind}, 'essentia-feature-sqlite-v3',
    'resource has the native SPI kind');
is($bundle->{resources}[0]{access}, 'read_only', 'SPI resource is readonly');
ok(-s $bundle->{resources}[0]{path} < 4*1024*1024, 'projected sidecar is bounded');
is($bundle->{artifacts}[0]{kind}, 'essentia-exact-track-keys-v1',
    'uses existing versioned SPI artifact');
like($bundle->{artifacts}[0]{sha256}, qr/\A[a-f0-9]{64}\z/,
    'identity artifact retains full SHA-256 digest');
is($bundle->{options}{model_id}, 'genre', 'selects model in canonical SPI options');
is($bundle->{options}{expected_model_key}, 'pinned-genre',
    'passes exact pinned feature fingerprint');
ok(!JSON::PP::is_bool($bundle->{options}{experimental_preview_opt_in})
    ? 0 : !$bundle->{options}{experimental_preview_opt_in},
    'preview disabled using a serialized JSON boolean');
is_deeply([map { $_->{candidate_id} } @{$bundle->{candidates}}],
    [map { $_->url } @items[1,2]], 'candidate cohort/order preserved exactly');
is_deeply($bundle->{context}{context_track_ids}, [$items[0]->url],
    'one exact global anchor in context');
is($bundle->{anchors}[0]{candidate_id}, $items[0]->url,
    'native anchor binds same seed as context');
is($bundle->{job_id}, 'offline-spi-proof', 'job ID is explicitly pinned');
my $disk = db($bundle->{resources}[0]{path});
is($disk->selectrow_array('SELECT count(*) FROM feature_tracks'), 3,
    'only the bounded admitted cohort is exported');
$disk->disconnect;

my $before = [glob(File::Spec->catfile($dir, 'essentia-provider-*'))];
my $denied = eval {
    Plugins::EssentiaGuidance::SpiResourceBundle::assemble_research_bundle(
        %args, research_only => 0);
    1;
};
ok(!$denied, 'offline fixture cannot be invoked without explicit research opt-in');
my $after = [glob(File::Spec->catfile($dir, 'essentia-provider-*'))];
is(scalar(@$after), scalar(@$before), 'disabled bundle does not allocate a new directory');
my $bad = eval {
    Plugins::EssentiaGuidance::SpiResourceBundle::assemble_research_bundle(
        %args, expected_model_key => 'wrong-model');
    1;
};
ok(!$bad, 'model fingerprint mismatch rejects whole research bundle');
$after = [glob(File::Spec->catfile($dir, 'essentia-provider-*'))];
is(scalar(@$after), scalar(@$before), 'failed bundle leaves no resource directory');
$bad = eval {
    Plugins::EssentiaGuidance::SpiResourceBundle::assemble_research_bundle(
        %args, media_dirs => ['/music', '/other']);
    1;
};
ok(!$bad, 'no multi-root identity is claimed without scanner provenance');
$after = [glob(File::Spec->catfile($dir, 'essentia-provider-*'))];
is(scalar(@$after), scalar(@$before), 'ambiguous roots fail without resource leakage');
ok(!Plugins::EssentiaGuidance::Provider::guidance_provider_status_v1()->{available},
    'offline synthetic SPI envelope does not enable actual Lyrion provider');

done_testing;
