package Plugins::EssentiaGuidance::SourceProvenance;

use strict;
use warnings;

use Cwd qw(abs_path);
use Digest::SHA ();
use File::Spec;
use Time::HiRes qw(stat);

# Offline, provider-owned content attestation for current scanner v3.
# This is NOT a cross-database generation witness and cannot enable the
# production Provider.pm factory. No source/feature/database writes.
sub attest_cohort {
    my (%args) = @_;
    die 'offline research opt-in required'
        unless defined($args{research_only}) && !ref($args{research_only})
            && "$args{research_only}" eq '1';
    my ($anchors, $candidates, $roots, $bliss, $features) =
        @args{qw(anchors candidates media_dirs bliss_dbh feature_dbh)};
    die 'one seed and 2..50 admitted candidates required'
        unless ref($anchors) eq 'ARRAY' && @$anchors == 1
            && ref($candidates) eq 'ARRAY' && @$candidates >= 2
            && @$candidates <= 50;
    die '1..32 configured host roots required'
        unless ref($roots) eq 'ARRAY' && @$roots >= 1 && @$roots <= 32;
    die 'pinned database handles required' unless $bliss && $features;
    die 'source databases must be query-only'
        unless $bliss->selectrow_array('PRAGMA query_only') == 1
            && $features->selectrow_array('PRAGMA query_only') == 1;
    die 'feature source must be SQLite v3'
        unless $features->selectrow_array('PRAGMA user_version') == 3;
    my ($model, $fingerprint) = @args{qw(model_id expected_model_key)};
    die 'pinned model and fingerprint required'
        unless defined($model) && !ref($model) && $model =~ /\A(?:genre|moodtheme)\z/
            && defined($fingerprint) && !ref($fingerprint)
            && $fingerprint =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
    my ($validated) = $features->selectrow_array(
        'SELECT validated_against_essentia FROM feature_models WHERE model_key = ? COLLATE BINARY',
        undef, $fingerprint);
    die 'unvalidated or missing model fingerprint'
        unless defined($validated) && $validated == 1;

    my @canonical_roots;
    my %seen_root;
    for my $root (@$roots) {
        die 'invalid or symlinked music root'
            unless defined($root) && !ref($root) && length($root)
                && File::Spec->file_name_is_absolute($root) && -d $root
                && !-l $root && index($root, "\0") == -1
                && !_unsafe_components($root);
        my $real = abs_path($root);
        die 'noncanonical or duplicate music root'
            unless defined($real) && $real eq $root && !$seen_root{$real}++;
        push @canonical_roots, $real;
    }

    my $max_file_bytes = defined($args{max_file_bytes})
        ? $args{max_file_bytes} : 2 * 1024 * 1024 * 1024;
    my $max_total_bytes = defined($args{max_total_bytes})
        ? $args{max_total_bytes} : 8 * 1024 * 1024 * 1024;
    die 'invalid streaming hash byte budgets'
        unless $max_file_bytes =~ /\A[1-9][0-9]*\z/
            && $max_total_bytes =~ /\A[1-9][0-9]*\z/
            && $max_file_bytes <= $max_total_bytes;

    my $bliss_q = $bliss->prepare(
        'SELECT count(*) FROM TracksV2 WHERE File = ? COLLATE BINARY AND Ignore IS NOT 1');
    my $feature_q = $features->prepare(q{
        SELECT t.audio_sha256, t.model_key, s.file_size, s.model_key AS state_model_key
          FROM feature_tracks t
          JOIN feature_track_state s ON s.track_file = t.track_file COLLATE BINARY
                                    AND s.model_id = t.model_id COLLATE BINARY
         WHERE t.track_file = ? COLLATE BINARY
           AND t.model_id = ? COLLATE BINARY
    });
    my (%seen_ids, %seen_keys, @verified, $bytes_hashed);
    $bytes_hashed = 0;
    for my $track (@$anchors, @$candidates) {
        die 'invalid trusted host track' unless $track;
        my $id = eval { $track->url };
        my $path = eval { $track->path };
        die 'invalid local host identity or CUE/stream source'
            unless defined($id) && !ref($id) && length($id) <= 4096
                && $id =~ /\Afile:\/\//i && index($id, '#') < 0
                && index($id, "\0") < 0
                && defined($path) && !ref($path) && length($path) <= 4096
                && File::Spec->file_name_is_absolute($path)
                && !_unsafe_components($path) && !-l $path && -f $path
                && index($path, "\0") < 0;
        my $canonical_path = abs_path($path);
        die 'track path escapes root or uses symlink alias'
            unless defined($canonical_path) && $canonical_path eq $path;
        my @owners;
        for my $root (@canonical_roots) {
            my $prefix = $root eq '/' ? '/' : "$root/";
            next unless index($canonical_path, $prefix) == 0;
            my $key = substr($canonical_path, length($prefix));
            push @owners, [$root, $key] if length($key);
        }
        die 'track has missing or ambiguous owning music root'
            unless @owners == 1;
        my ($root, $key) = @{$owners[0]};
        die 'unsafe scanner-relative track key' if _unsafe_components($key);
        die 'duplicate host track ID or scanner key'
            if $seen_ids{$id}++ || $seen_keys{$key}++;
        # Scanner v3 stores keys without a root namespace. If another
        # configured root contains the same key, source identity is ambiguous.
        for my $other (@canonical_roots) {
            next if $other eq $root;
            my $other_path = File::Spec->catfile($other, split m{/}, $key);
            die 'same scanner key exists under multiple music roots'
                if -e $other_path || -l $other_path;
        }

        $bliss_q->execute($key);
        my ($n_bliss) = $bliss_q->fetchrow_array;
        die 'missing or ambiguous exact Bliss catalogue key'
            unless defined($n_bliss) && $n_bliss == 1;
        $feature_q->execute($key, $model);
        my $row = $feature_q->fetchrow_hashref;
        die 'no scanner state for the exact model head' unless $row;
        die 'duplicate scanner model head' if $feature_q->fetchrow_hashref;
        die 'stale, malformed or mismatched scanner model state'
            unless defined($row->{model_key}) && $row->{model_key} eq $fingerprint
                && defined($row->{state_model_key})
                && $row->{state_model_key} eq $fingerprint
                && defined($row->{file_size})
                && $row->{file_size} =~ /\A[0-9]+\z/
                && defined($row->{audio_sha256})
                && $row->{audio_sha256} =~ /\A[a-f0-9]{64}\z/;

        my @before = stat($path);
        die 'unreadable audio source' unless @before;
        my ($dev, $inode, $size, $mtime) = @before[0,1,7,9];
        die 'scanner size or source byte budget mismatch'
            unless $size == $row->{file_size} && $size > 0
                && $size <= $max_file_bytes
                && $size <= $max_total_bytes - $bytes_hashed;
        open my $fh, '<:raw', $path or die 'audio hash source unavailable';
        my @fd_before = stat($fh);
        die 'audio path replaced before file was opened'
            unless @fd_before && $fd_before[0] == $dev
                && $fd_before[1] == $inode && $fd_before[7] == $size
                && $fd_before[9] == $mtime;
        my $digest = Digest::SHA->new(256);
        my ($read_bytes, $chunk) = (0, '');
        while (1) {
            my $count = read($fh, $chunk, 1024 * 1024);
            die 'audio source read failure' unless defined($count);
            last if $count == 0;
            $read_bytes += $count;
            die 'source grew during hashing' if $read_bytes > $size;
            $digest->add(substr($chunk, 0, $count));
        }
        my @fd_after = stat($fh);
        close($fh) or die 'cannot close audio source';
        my @after = stat($path);
        die 'audio modified or swapped during verification'
            unless $read_bytes == $size
                && @fd_after && @after
                && $fd_after[0] == $dev && $fd_after[1] == $inode
                && $fd_after[7] == $size && $fd_after[9] == $mtime
                && $after[0] == $dev && $after[1] == $inode
                && $after[7] == $size && $after[9] == $mtime;
        die 'audible source and scanner SHA-256 disagree'
            unless $digest->hexdigest eq $row->{audio_sha256};
        $bytes_hashed += $size;
        push @verified, { track_id => "$id", track_file => "$key" };
    }
    $bliss_q->finish;
    $feature_q->finish;
    return {
        kind => 'essentia-audio-content-cohort-v1',
        tracks => \@verified,
        verified_count => scalar(@verified),
        music_root_count => scalar(@canonical_roots),
        bytes_hashed => $bytes_hashed,
        # Deliberately no generation_validated flag.
    };
}

sub _unsafe_components {
    my $path = shift;
    return 1 unless defined($path) && !ref($path) && length($path);
    return 1 if index($path, "\0") >= 0 || index($path, '\\') >= 0;
    return 1 if $path =~ m{(?:\A|/)\.\.?(?:/|\z)};
    return 1 if $path =~ m{//};
    return 0;
}

1;
