use strict;
use warnings;

use Digest::SHA ();
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'SQLite Perl driver unavailable';
}
use lib "$FindBin::Bin/..";
require 'EssentiaGuidance/BoundedSnapshot.pm';
require 'EssentiaGuidance/CatalogFingerprint.pm';

my $dir = tempdir(CLEANUP => 1);
my $music_a = File::Spec->catdir($dir, 'root-a');
my $music_b = File::Spec->catdir($dir, 'root-b');
make_path($music_a, $music_b);
my $db_path = File::Spec->catfile($dir, 'bliss.db');
my $w = DBI->connect("dbi:SQLite:dbname=$db_path", '', '', {
    RaiseError => 1, PrintError => 0, AutoCommit => 1,
    sqlite_unicode => 1,
});
$w->do('PRAGMA journal_mode=WAL');
$w->do('CREATE TABLE TracksV2(File TEXT, Ignore INTEGER)');
for my $key ('Artist/A.flac', 'Artist/B.flac', 'Artist/C.flac') {
    $w->do('INSERT INTO TracksV2 VALUES (?,0)', undef, $key);
}
$w->do('INSERT INTO TracksV2 VALUES (?,1)', undef, 'Ignore/me.flac');
my $read = Plugins::EssentiaGuidance::BoundedSnapshot::open_source($db_path);
my @roots = (
    {root_id => 'speaker-room-a', host_path => $music_a},
    {root_id => 'speaker-room-b', host_path => $music_b},
);
my $compute = sub {
    my (%override) = @_;
    return Plugins::EssentiaGuidance::CatalogFingerprint::snapshot(
        research_only => 1, bliss_dbh => $read, roots => \@roots, %override,
    );
};
my $first = $compute->();
is($first->{kind}, 'essentia-bliss-catalog-fingerprint-v1',
    'exact versioned content fingerprint, no invented host generation');
is($first->{eligible_tracks}, 3, 'ignored tracks excluded from catalog');
is($first->{root_count}, 2, 'root-map identity included');
is($first->{generation_verified}, 0, 'content fingerprint never claims a Lyrion scan epoch');
for my $key (qw(catalog_sha256 host_root_map_sha256 fingerprint_sha256)) {
    like($first->{$key}, qr/\A[a-f0-9]{64}\z/, "$key is a SHA256 fingerprint");
}
my $same = $compute->(roots => [reverse @roots]);
is($first->{fingerprint_sha256}, $same->{fingerprint_sha256},
    'root order does not change stable fingerprint');
my $fresh = Plugins::EssentiaGuidance::CatalogFingerprint::assert_fresh(
    research_only => 1, bliss_db => $db_path, roots => \@roots, expected => $first,
);
is($fresh->{fingerprint_sha256}, $first->{fingerprint_sha256},
    'fresh read-only catalog with unchanged roots matches');

# A separate writer commits during the first pinned read transaction.
$w->do('INSERT INTO TracksV2 VALUES (?,0)', undef, 'Artist/New.flac');
is($compute->()->{fingerprint_sha256}, $first->{fingerprint_sha256},
    'old WAL snapshot is stable and therefore not a freshness proof');
my $stale = eval {
    Plugins::EssentiaGuidance::CatalogFingerprint::assert_fresh(
        research_only => 1, bliss_db => $db_path, roots => \@roots, expected => $first);
    1;
};
ok(!$stale, 'fresh second SQLite transaction detects a concurrent catalog change');
$read->do('ROLLBACK');
$read->disconnect;
$read = Plugins::EssentiaGuidance::BoundedSnapshot::open_source($db_path);
my $second = $compute->();
is($second->{eligible_tracks}, 4, 'new pinned snapshot sees the new catalog');
my $root_changed = eval {
    Plugins::EssentiaGuidance::CatalogFingerprint::assert_fresh(
        research_only => 1, bliss_db => $db_path,
        roots => [{root_id => 'changed-root', host_path => $music_a}, $roots[1]],
        expected => $second);
    1;
};
ok(!$root_changed, 'root ID reconfiguration invalidates fingerprint');

my $nested = File::Spec->catdir($music_a, 'nested');
make_path($nested);
for my $test (
    [{root_id => 'a', host_path => $music_a},
     {root_id => 'b', host_path => $nested}],
    [{root_id => 'a', host_path => $music_a},
     {root_id => 'a', host_path => $music_b}],
    [{root_id => 'a', host_path => "$music_a/.."}],
    [{root_id => 'a', host_path => $music_a},
     {root_id => 'b', host_path => $music_a}],
) {
    my $ok = eval { $compute->(roots => $test); 1 };
    ok(!$ok, 'ambiguous, duplicate or noncanonical host roots rejected');
}
for my $params (
    {max_tracks => 1}, {max_catalog_bytes => 10},
    {max_catalog_bytes => 256 * 1024 * 1024 + 1},
) {
    my $ok = eval { $compute->(%$params); 1 };
    ok(!$ok, 'bounded catalog I/O and memory limits reject oversize inputs');
}
my $disabled = eval { $compute->(research_only => 0); 1 };
ok(!$disabled, 'manual research opt-in required');
my $write_handle = eval {
    Plugins::EssentiaGuidance::CatalogFingerprint::snapshot(
        research_only => 1, bliss_dbh => $w, roots => \@roots);
    1;
};
ok(!$write_handle, 'writable SQLite handle is never accepted');

# Duplicate keys can arise without a unique DB constraint; never allow
# an ambiguous catalog fingerprint to pass as a unique track mapping.
$read->do('ROLLBACK');
$read->disconnect;
$w->do('INSERT INTO TracksV2 VALUES (?,0)', undef, 'Artist/A.flac');
$read = Plugins::EssentiaGuidance::BoundedSnapshot::open_source($db_path);
my $duplicate = eval { $compute->(); 1 };
ok(!$duplicate, 'duplicate exact eligible keys fail as an entire snapshot');
$read->do('ROLLBACK');
$read->disconnect;
$w->disconnect;

done_testing();
