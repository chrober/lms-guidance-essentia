use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'SQLite Perl driver unavailable';
}

{
    package ProvenanceFixtureTrack;
    sub new { bless { url => $_[1], path => $_[2] }, $_[0] }
    sub url { $_[0]->{url} }
    sub path { $_[0]->{path} }
}
use lib "$FindBin::Bin/..";
require 'EssentiaGuidance/BoundedSnapshot.pm';
require 'EssentiaGuidance/SourceProvenance.pm';

sub db {
    my $path = shift;
    return DBI->connect("dbi:SQLite:dbname=$path", '', '', {
        RaiseError => 1, PrintError => 0, AutoCommit => 1,
    });
}
sub write_audio {
    my ($path, $content) = @_;
    open my $out, '>:raw', $path or die $!;
    print {$out} $content or die $!;
    close $out or die $!;
}
sub run_audit {
    my (%override) = @_;
    return Plugins::EssentiaGuidance::SourceProvenance::attest_cohort(
        research_only => 1, anchors => [$seed], candidates => [$a, $b],
        media_dirs => \@roots, bliss_dbh => $bliss, feature_dbh => $features,
        model_id => 'genre', expected_model_key => 'pinned-v3',
        max_file_bytes => 4096, max_total_bytes => 8192, %override,
    );
}

my $dir = tempdir('provenance-fixture-XXXXXXXX', TMPDIR => 1, CLEANUP => 1);
my $root_a = "$dir/rootA";
my $root_b = "$dir/rootB";
make_path($root_a, $root_b);
my @roots = ($root_a, $root_b);
my @keys = ('seed.flac', 'a.flac', 'b.flac');
my @paths = ("$root_a/seed.flac", "$root_a/a.flac", "$root_b/b.flac");
my @audio = ('SEED original audio', 'A original audio', 'B original audio');
for (0..2) { write_audio($paths[$_], $audio[$_]); }
my $seed = ProvenanceFixtureTrack->new('file:///rootA/seed.flac', $paths[0]);
my $a = ProvenanceFixtureTrack->new('file:///rootA/a.flac', $paths[1]);
my $b = ProvenanceFixtureTrack->new('file:///rootB/b.flac', $paths[2]);

my $bliss_file = File::Spec->catfile($dir, 'bliss.db');
my $features_file = File::Spec->catfile($dir, 'features.db');
my $wb = db($bliss_file);
$wb->do('CREATE TABLE TracksV2 (File TEXT NOT NULL, Ignore INTEGER)');
my $wf = db($features_file);
$wf->do('PRAGMA user_version=3');
$wf->do(q{CREATE TABLE feature_models (
    model_key TEXT PRIMARY KEY, validated_against_essentia INTEGER)});
$wf->do(q{CREATE TABLE feature_tracks (
    track_file TEXT NOT NULL, model_id TEXT NOT NULL,
    audio_sha256 TEXT NOT NULL, model_key TEXT NOT NULL,
    PRIMARY KEY(track_file, model_id))});
$wf->do(q{CREATE TABLE feature_track_state (
    track_file TEXT NOT NULL, model_id TEXT NOT NULL, file_size INTEGER NOT NULL,
    modified_ns INTEGER NOT NULL, model_key TEXT NOT NULL,
    PRIMARY KEY(track_file,model_id))});
$wf->do('INSERT INTO feature_models VALUES (?,1)', undef, 'pinned-v3');
for (0..2) {
    $wb->do('INSERT INTO TracksV2 VALUES (?,0)', undef, $keys[$_]);
    $wf->do('INSERT INTO feature_tracks VALUES (?,?,?,?)', undef,
        $keys[$_], 'genre', sha256_hex($audio[$_]), 'pinned-v3');
    $wf->do('INSERT INTO feature_track_state VALUES (?,?,?,?,?)', undef,
        $keys[$_], 'genre', length($audio[$_]), 0, 'pinned-v3');
}
$wb->disconnect;
$wf->disconnect;
my $bliss = Plugins::EssentiaGuidance::BoundedSnapshot::open_source($bliss_file);
my $features = Plugins::EssentiaGuidance::BoundedSnapshot::open_source($features_file);

my $proof = run_audit();
is($proof->{kind}, 'essentia-audio-content-cohort-v1',
    'auditor declares a content-only proof, not a generation proof');
is($proof->{verified_count}, 3, 'one seed and two candidate files audited');
is($proof->{music_root_count}, 2, 'separate physical music roots accepted');
is_deeply([map { $_->{track_file} } @{$proof->{tracks}}], \@keys,
    'scan keys and original seed/candidate order preserved');
is($proof->{bytes_hashed}, length(join('', @audio)),
    'actual complete source bytes were streamed into SHA-256');
ok(!exists($proof->{generation_validated}),
    'content attestation does not pretend cross-database generation equality');

write_audio("$root_b/a.flac", 'other physical recording');
my $collision = eval { run_audit(); 1 };
ok(!$collision, 'duplicated relative track key across roots rejected');
unlink("$root_b/a.flac");

my $same_size = 'A updated audio!!';
is(length($same_size), length($audio[1]), 'same-size mutation fixture');
write_audio($paths[1], $same_size);
my $mutated = eval { run_audit(); 1 };
ok(!$mutated, 'same-length but different content rejects stale scanner features');
write_audio($paths[1], $audio[1]);

my $wrong_model = eval { run_audit(expected_model_key => 'wrong-model'); 1 };
ok(!$wrong_model, 'unknown model fingerprint rejected');
my $too_small = eval { run_audit(max_total_bytes => 8); 1 };
ok(!$too_small, 'bounded hash I/O budget prevents unbounded scanning');
my $fake = ProvenanceFixtureTrack->new('https://example.org/audio', $paths[1]);
my $stream = eval { run_audit(candidates => [$fake, $b]); 1 };
ok(!$stream, 'nonlocal stream is never treated as scanner audio');

symlink($paths[1], "$root_a/alias.flac") or die $!;
my $symlinked = ProvenanceFixtureTrack->new('file:///rootA/alias.flac',
    "$root_a/alias.flac");
my $alias = eval { run_audit(candidates => [$symlinked, $b]); 1 };
ok(!$alias, 'symbolic-link aliases are rejected as ambiguous identity');

my $duplicated = eval { run_audit(candidates => [$a, $a]); 1 };
ok(!$duplicated, 'duplicate host candidate rejected');

my $unclean_root = eval { run_audit(media_dirs => ["$root_a/.", $root_b]); 1 };
ok(!$unclean_root, 'noncanonical music root is rejected');
my $same_root_twice = eval { run_audit(media_dirs => [$root_a, $root_a]); 1 };
ok(!$same_root_twice, 'duplicated configured music root rejected');

my $unclean_path = ProvenanceFixtureTrack->new(
    'file:///rootB/../rootB/b.flac', "$root_b/../rootB/b.flac");
my $traversal = eval { run_audit(candidates => [$a, $unclean_path]); 1 };
ok(!$traversal, 'parent-directory track alias is rejected');

$bliss->do('ROLLBACK');
$features->do('ROLLBACK');
$bliss->disconnect;
$features->disconnect;

my $write_prohibited = eval {
    Plugins::EssentiaGuidance::SourceProvenance::attest_cohort(
        research_only => 1, anchors => [$seed], candidates => [$a, $b],
        media_dirs => \@roots, bliss_dbh => db($bliss_file),
        feature_dbh => db($features_file),
        model_id => 'genre', expected_model_key => 'pinned-v3');
    1;
};
ok(!$write_prohibited, 'writable source handles cannot masquerade as pinned readonly snapshots');
my $not_opted = eval {
    Plugins::EssentiaGuidance::SourceProvenance::attest_cohort(
        research_only => 0);
    1;
};
ok(!$not_opted, 'offline content audit requires an explicit research opt-in');

done_testing();
