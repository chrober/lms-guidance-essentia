package Plugins::EssentiaGuidance::ExactIdentity;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP ();

# Internal experimental provider helper, never wired into a host DSTM. The host must supply
# independently opened, read-only, snapshot-consistent database handles.
# This module never infers identity from urlmd5, artist/title or case folding.
sub verifier_from_db_handles {
    my ($bliss_dbh, $feature_dbh) = @_;
    die 'read-only database handles are required'
        unless $bliss_dbh && $feature_dbh;

    my $bliss = $bliss_dbh->prepare(
        'SELECT COUNT(*) FROM TracksV2 WHERE File = ? COLLATE BINARY AND Ignore IS NOT 1'
    );
    my $features = $feature_dbh->prepare(
        'SELECT EXISTS(SELECT 1 FROM feature_tracks WHERE track_file = ? COLLATE BINARY)'
    );
    die 'exact identity verification unavailable' unless $bliss && $features;

    return sub {
        my ($key) = @_;
        return 0 unless defined $key && length $key;
        my $valid = eval {
            $bliss->execute($key);
            my ($bliss_count) = $bliss->fetchrow_array();
            $features->execute($key);
            my ($feature_present) = $features->fetchrow_array();
            defined $bliss_count && $bliss_count == 1
                && defined $feature_present && $feature_present == 1;
        };
        return $valid ? 1 : 0;
    };
}

# One global anchor and 2..50 already host-admitted candidates.
# All inputs are trusted host-owned objects; the provider owns the second
# check of keys, model fingerprints and actual Essentia feature validity.
sub write_artifact {
    my (%args) = @_;
    my $anchors = $args{anchors};
    my $candidates = $args{candidates};
    my $roots = $args{media_dirs};
    my $verify = $args{verify_key};
    my $job_id = $args{job_id};
    my $directory = $args{directory};
    my $windows = $args{windows} ? 1 : 0;
    # Optional OFFLINE host-route binding. A SPI anchor_id ("seed-1") is
    # a job-local token, not the Lyrion URL. Accept it only when its
    # candidate_id AND lms_urlmd5 match the trusted seed track object.
    my $seed_binding = $args{seed_anchor_binding};
    if (defined $seed_binding) {
        die 'malformed host seed anchor binding'
            unless ref($seed_binding) eq 'HASH'
                && defined($seed_binding->{anchor_id})
                && !ref($seed_binding->{anchor_id})
                && $seed_binding->{anchor_id} =~ /\Aseed-[1-9][0-9]{0,5}\z/
                && defined($seed_binding->{candidate_id})
                && !ref($seed_binding->{candidate_id})
                && defined($seed_binding->{lms_urlmd5})
                && !ref($seed_binding->{lms_urlmd5})
                && $seed_binding->{lms_urlmd5} =~ /\A[a-f0-9]{32}\z/i;
        die 'host seed is not the original Lyrion source identity'
            unless ref($anchors) eq 'ARRAY' && @$anchors == 1
                && defined(eval { $anchors->[0]->url })
                && $seed_binding->{candidate_id} eq $anchors->[0]->url
                && defined(eval { $anchors->[0]->urlmd5 })
                && $seed_binding->{lms_urlmd5} eq $anchors->[0]->urlmd5;
    }

    die 'one anchor is required'
        unless ref($anchors) eq 'ARRAY' && @$anchors == 1;
    die 'bounded complete candidate list required'
        unless ref($candidates) eq 'ARRAY' && @$candidates >= 2 && @$candidates <= 50;
    die 'trusted media directories required'
        unless ref($roots) eq 'ARRAY' && @$roots && @$roots <= 32;
    die 'exact database verifier required' unless ref($verify) eq 'CODE';
    die 'valid job ID required'
        unless defined($job_id) && $job_id =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
    die 'trusted artifact directory required'
        unless defined($directory) && -d $directory;

    my (%seen_ids, %seen_keys, @tracks);
    my $index = 0;
    for my $track (@$anchors, @$candidates) {
        my ($id, $key) = _exact_file_key($track, $roots, $windows);
        if ($index == 0 && $seed_binding) {
            # Preserve only the verified route token as the pinned artifact
            # key. The actual song URL is carried separately in the SPI
            # anchor candidate_id; candidates keep their original file URLs.
            $id = $seed_binding->{anchor_id};
        }
        die 'duplicate track identity' if $seen_ids{$id}++;
        die 'ambiguous track key' if $seen_keys{$key}++;
        die 'unverified exact feature identity' unless $verify->($key);
        push @tracks, {
            track_id => $id, track_file => $key,
            ($index == 0 && $seed_binding
                ? (source_url => $seed_binding->{candidate_id},
                   lms_urlmd5 => $seed_binding->{lms_urlmd5}) : ()),
        };
        $index++;
    }

    return _emit_artifact(\@tracks, $job_id, $directory,
        $seed_binding ? 1 : 0);
}

# Offline-only bridge from the stronger, independently audited content proof.
# Do not accept caller assertions as production attestation: the public
# Provider factory remains unavailable until a joint generation witness exists.
sub write_content_attested_artifact {
    my (%args) = @_;
    die 'content audit requires explicit offline research opt-in'
        unless defined($args{research_only}) && !ref($args{research_only})
            && "$args{research_only}" eq '1';
    my $proof = $args{proof};
    die 'complete content-audited cohort required'
        unless ref($proof) eq 'HASH'
            && ($proof->{kind} || '') eq 'essentia-audio-content-cohort-v1'
            && ref($proof->{tracks}) eq 'ARRAY'
            && defined($proof->{verified_count})
            && $proof->{verified_count} == @{$proof->{tracks}};
    return _emit_artifact($proof->{tracks}, $args{job_id}, $args{directory});
}

sub _emit_artifact {
    my ($tracks, $job_id, $directory, $bound_seed_alias) = @_;
    die 'complete bounded cohort required'
        unless ref($tracks) eq 'ARRAY' && @$tracks >= 3 && @$tracks <= 51;
    die 'valid job ID required'
        unless defined($job_id) && !ref($job_id)
            && $job_id =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
    die 'trusted artifact directory required'
        unless defined($directory) && !ref($directory)
            && -d $directory && !-l $directory;
    my (%ids, %keys);
    my $row_index = 0;
    for my $row (@$tracks) {
        die 'invalid verified row' unless ref($row) eq 'HASH';
        my ($id, $key) = @$row{qw(track_id track_file)};
        my $source_url = defined($id) && !ref($id)
            && $id =~ /\Afile:\/\//i;
        my $verified_host_token = $bound_seed_alias && $row_index == 0
            && defined($id) && !ref($id)
            && $id =~ /\Aseed-[1-9][0-9]{0,5}\z/;
        # Route-alias provenance must survive inside the SHA-256-pinned
        # artifact so the independent native process can recheck that
        # anchor.candidate_id and lms_urlmd5 really belong to seed-N.
        die 'unverified original seed identity in artifact'
            if $verified_host_token && (
                !defined($row->{source_url}) || ref($row->{source_url})
                || $row->{source_url} !~ /\Afile:\/\//i
                || length($row->{source_url}) > 4096
                || !defined($row->{lms_urlmd5}) || ref($row->{lms_urlmd5})
                || $row->{lms_urlmd5} !~ /\A[a-f0-9]{32}\z/i
            );
        die 'unbound source assertion in non-anchor row'
            if !$verified_host_token
                && (exists $row->{source_url} || exists $row->{lms_urlmd5});
        die 'duplicate/unsafe verified row'
            unless defined($id) && !ref($id) && length($id) <= 4096
                && ($source_url || $verified_host_token)
                && index($id, "\0") < 0
                && defined($key) && !ref($key) && length($key)
                && length($key) <= 4096 && index($key, "\0") < 0
                && $key !~ m{(?:\A|/)\.\.?(?:/|\z)}
                && $key !~ m{//} && $key !~ m{\A/}
                && !$ids{$id}++ && !$keys{$key}++;
        $row_index++;
    }
    my $bytes = JSON::PP->new->canonical->utf8->encode({
        schema => 'essentia-exact-track-keys-v1',
        schema_version => 1, job_id => $job_id, tracks => $tracks,
    });
    die 'identity artifact exceeds provider limit' if length($bytes) > 256 * 1024;

    my ($fh, $path) = tempfile('essentia-exact-keys-XXXXXX',
        DIR => $directory, UNLINK => 0);
    binmode($fh, ':raw');
    my $ok = eval {
        print {$fh} $bytes or die 'cannot write identity artifact';
        close($fh) or die 'cannot close identity artifact';
        1;
    };
    unless ($ok) {
        close($fh);
        unlink($path);
        die 'cannot write identity artifact';
    }
    return { kind => 'essentia-exact-track-keys-v1',
             path => $path, sha256 => sha256_hex($bytes) };
}

sub _exact_file_key {
    my ($track, $roots, $windows) = @_;
    die 'missing track object' unless $track;

    my $id = eval { $track->url };
    my $path = eval { $track->path };
    die 'missing exact local track identity'
        unless defined($id) && length($id) && length($id) <= 4096
            && defined($path) && length($path) && length($path) <= 4096
            && index($id, "\0") == -1 && index($path, "\0") == -1;
    die 'nonlocal LMS source' unless $id =~ /\Afile:\/\//i;
    $path =~ s{\\}{/}g if $windows;
    die 'nonabsolute local track' unless _absolute($path, $windows);

    # TracksV2.File records only a relative path, not which LMS music root
    # originally owned it. Distinct roots can contain the same relative
    # file name. Never treat a two-database key hit as root provenance.
    my %unique_roots;
    for my $root (@$roots) {
        die 'invalid media root' unless defined($root) && length($root);
        my $clean = $root;
        $clean =~ s{\\}{/}g if $windows;
        $clean =~ s{/$}{} unless $clean eq '/';
        die 'invalid media root'
            unless _absolute($clean, $windows)
                && $clean !~ m{(?:\A|/)\.\.?(?:/|\z)};
        $unique_roots{$clean} = 1;
    }
    die 'multi-root provenance unavailable' unless keys(%unique_roots) == 1;

    my %matched;
    for my $root (keys %unique_roots) {
        next unless defined($root) && length($root) && index($root, "\0") == -1;
        my $clean = $root;
        $clean =~ s{\\}{/}g if $windows;
        $clean =~ s{/$}{} unless $clean eq '/';
        next unless _absolute($clean, $windows);
        my $prefix = $clean eq '/' ? '/' : "$clean/";
        next unless index($path, $prefix) == 0;
        my $relative = substr($path, length($prefix));
        next unless length($relative);
        next if $relative =~ m{(?:\A|/)\.\.?(?:/|\z)};
        $matched{$relative} = 1;
    }
    my @keys = keys %matched;
    die 'missing or ambiguous media root' unless @keys == 1;

    my $key = $keys[0];
    if (index($id, '#') >= 0) {
        my @parts = split /#/, $id, -1;
        my $number = eval { $track->tracknum };
        die 'unverified CUE track identity'
            unless @parts == 2 && $parts[1] =~ /\A[0-9]+(?:\.[0-9]+)?-[0-9]+(?:\.[0-9]+)?\z/
                && defined($number) && $number =~ /\A[1-9][0-9]*\z/;
        $key .= '.CUE_TRACK.' . $number;
    }
    return ("$id", $key);
}

sub _absolute {
    my ($path, $windows) = @_;
    return 0 unless defined $path;
    return $path =~ m{\A(?:[A-Za-z]:/|//[^/]+/[^/]+(?:/|\z))} if $windows;
    return $path =~ m{\A/};
}

1;
