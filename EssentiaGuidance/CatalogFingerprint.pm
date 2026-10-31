package Plugins::EssentiaGuidance::CatalogFingerprint;

use strict;
use warnings;

use Cwd qw(abs_path);
use Digest::SHA ();
use Encode qw(encode FB_CROAK);
use File::Spec;
use Plugins::EssentiaGuidance::BoundedSnapshot ();

# An exact, bounded fingerprint of the *Bliss TracksV2 catalog* and the
# host's currently configured physical music roots. NOT a Lyrion scan epoch.
# Research-only; never supplied to Provider::guidance_provider_status_v1.
sub snapshot {
    my (%arg) = @_;
    die 'offline research opt-in required'
        unless defined($arg{research_only}) && !ref($arg{research_only})
            && "$arg{research_only}" eq '1';
    my $db = $arg{bliss_dbh};
    die 'pinned readonly Bliss handle required'
        unless $db && $db->selectrow_array('PRAGMA query_only') == 1;
    my $roots = $arg{roots};
    die '1..32 trusted host roots required'
        unless ref($roots) eq 'ARRAY' && @$roots >= 1 && @$roots <= 32;
    my $max_tracks = defined($arg{max_tracks}) ? $arg{max_tracks} : 1_000_000;
    my $max_bytes = defined($arg{max_catalog_bytes})
        ? $arg{max_catalog_bytes} : 64 * 1024 * 1024;
    die 'invalid finite catalog scan limits'
        unless !ref($max_tracks) && $max_tracks =~ /\A[1-9][0-9]*\z/
            && $max_tracks <= 1_000_000
            && !ref($max_bytes) && $max_bytes =~ /\A[1-9][0-9]*\z/
            && $max_bytes <= 256 * 1024 * 1024;

    my (%seen_ids, %seen_paths, @roots);
    for my $row (@$roots) {
        die 'root manifest rows must be hashes' unless ref($row) eq 'HASH';
        my ($id, $path) = @$row{qw(root_id host_path)};
        die 'missing/duplicate stable root ID' unless defined($id) && !ref($id)
            && $id =~ /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
            && !$seen_ids{$id}++;
        die 'noncanonical or symlinked host root' unless defined($path)
            && !ref($path) && File::Spec->file_name_is_absolute($path)
            && -d $path && !-l $path && index($path, "\0") < 0;
        my $resolved = abs_path($path);
        die 'noncanonical or duplicate host root path' unless defined($resolved)
            && $resolved eq $path && !$seen_paths{$path}++;
        push @roots, {root_id => $id, host_path => $path};
    }
    @roots = sort { $a->{root_id} cmp $b->{root_id} } @roots;
    for my $i (0 .. $#roots) {
        for my $j ($i+1 .. $#roots) {
            my ($a, $b) = ($roots[$i]{host_path}, $roots[$j]{host_path});
            my $ap = $a eq '/' ? '/' : "$a/";
            my $bp = $b eq '/' ? '/' : "$b/";
            die 'nested roots have ambiguous source ownership'
                if index($a, $bp) == 0 || index($b, $ap) == 0;
        }
    }

    my $root_sha = Digest::SHA->new(256);
    _part($root_sha, 'essentia-host-root-map-v1');
    for my $row (@roots) {
        _part($root_sha, $row->{root_id});
        _part($root_sha, _utf8_bytes($row->{host_path}));
    }
    my $catalog_sha = Digest::SHA->new(256);
    _part($catalog_sha, 'bliss-tracks-v2-eligible-catalog-v1');
    my $stmt = $db->prepare(q{
        SELECT File, typeof(File) FROM TracksV2
         WHERE Ignore IS NOT 1 ORDER BY File COLLATE BINARY
    });
    $stmt->execute;
    my ($count, $bytes, $previous) = (0, 0, undef);
    while (my $row = $stmt->fetchrow_arrayref) {
        my ($key, $type) = @$row;
        die 'nontext or missing Bliss track file identity'
            unless defined($key) && $type eq 'text' && length($key) > 0;
        my $enc = _utf8_bytes($key);
        die 'invalid oversized track key' if length($enc) > 4096;
        die 'duplicate eligible Bliss track identity'
            if defined($previous) && $previous eq $enc;
        die 'catalog scan bounds exceeded'
            if ++$count > $max_tracks || length($enc) > $max_bytes - $bytes;
        $bytes += length($enc);
        $previous = $enc;
        _part($catalog_sha, $enc);
    }
    $stmt->finish;
    die 'no eligible Bliss songs' unless $count;
    my ($catalog, $root_map) = ($catalog_sha->hexdigest, $root_sha->hexdigest);
    my $combined = Digest::SHA->new(256);
    _part($combined, 'essentia-bliss-catalog-fingerprint-v1');
    _part($combined, $catalog);
    _part($combined, $root_map);
    return {
        kind => 'essentia-bliss-catalog-fingerprint-v1',
        catalog_sha256 => $catalog,
        host_root_map_sha256 => $root_map,
        fingerprint_sha256 => $combined->hexdigest,
        eligible_tracks => $count,
        encoded_track_bytes => $bytes,
        root_count => scalar(@roots),
        # Neither root IDs nor catalog bytes are a trusted scanner receipt.
        generation_verified => 0,
    };
}

# Reopen a FRESH source read transaction: re-reading an old pinned WAL
# snapshot can never detect a concurrent rescan. File is never created.
sub assert_fresh {
    my (%arg) = @_;
    my $expected = $arg{expected};
    die 'complete earlier catalog fingerprint required'
        unless ref($expected) eq 'HASH'
            && ($expected->{kind} || '') eq 'essentia-bliss-catalog-fingerprint-v1'
            && defined($expected->{fingerprint_sha256})
            && $expected->{fingerprint_sha256} =~ /\A[a-f0-9]{64}\z/;
    my $dbh = Plugins::EssentiaGuidance::BoundedSnapshot::open_source(
        $arg{bliss_db});
    my $actual = eval {
        snapshot(research_only => $arg{research_only}, bliss_dbh => $dbh,
            roots => $arg{roots},
            (defined($arg{max_tracks}) ? (max_tracks => $arg{max_tracks}) : ()),
            (defined($arg{max_catalog_bytes})
                ? (max_catalog_bytes => $arg{max_catalog_bytes}) : ()));
    };
    my $error = $@;
    eval { $dbh->do('ROLLBACK'); $dbh->disconnect; };
    die 'fresh catalog verification failed' if $error;
    die 'Bliss catalog or host music roots changed since admission'
        unless $actual->{fingerprint_sha256} eq $expected->{fingerprint_sha256}
            && $actual->{catalog_sha256} eq $expected->{catalog_sha256}
            && $actual->{host_root_map_sha256} eq $expected->{host_root_map_sha256}
            && $actual->{eligible_tracks} == $expected->{eligible_tracks};
    return $actual;
}

sub _utf8_bytes {
    my ($value) = @_;
    die 'untrusted non-scalar catalog content' if !defined($value) || ref($value);
    return encode('UTF-8', $value, FB_CROAK);
}

sub _part {
    my ($digest, $bytes) = @_;
    $digest->add(pack('N', length($bytes)), $bytes);
}

1;
