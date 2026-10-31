package Plugins::EssentiaGuidance::ImportedSidecarPilot;

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Path qw(remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Plugins::EssentiaGuidance::BoundedSnapshot ();
use Plugins::EssentiaGuidance::ExactIdentity ();

# Deliberately OFFLINE, explicit manual-import research ONLY.
# No audio decoding, full-file SHA, host rescan, background jobs, or
# live Provider factory. This proves a key/size/model-cohort match
# against a manually imported Windows SQLite-v3 sidecar, NOT actual
# audio-byte parity or a shared Lyrion/scanner generation.
sub assemble_pilot_bundle {
    my (%arg) = @_;
    die 'explicit offline research opt-in required'
        unless defined($arg{research_only}) && !ref($arg{research_only})
            && "$arg{research_only}" eq '1';
    die 'explicit passive-only mode required'
        unless defined($arg{passive_only}) && !ref($arg{passive_only})
            && "$arg{passive_only}" eq '1';
    my $preview = $arg{experimental_preview_opt_in};
    die 'explicit experimental preview value required'
        unless defined($preview) && !ref($preview)
            && "$preview" =~ /\A[01]\z/;
    my $model = $arg{model_id};
    die 'unsupported research model' unless defined($model)
        && !ref($model) && $model =~ /\A(?:genre|moodtheme)\z/;
    my $metric = $arg{metric};
    die 'unsupported research metric' unless defined($metric)
        && !ref($metric)
        && $metric =~ /\A(?:affine_cosine_v1|affine_centered_cosine_v1)\z/;
    my $fingerprint = $arg{expected_model_key};
    die 'missing pinned model fingerprint'
        unless defined($fingerprint) && !ref($fingerprint)
            && $fingerprint =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
    die 'exactly one host music root required for root-relative v3 keys'
        unless ref($arg{media_dirs}) eq 'ARRAY'
            && @{$arg{media_dirs}} == 1;
    my $root = $arg{media_dirs}[0];
    die 'noncanonical or unavailable Pi music root'
        unless defined($root) && !ref($root)
            && File::Spec->file_name_is_absolute($root)
            && -d $root && !-l $root
            && defined(abs_path($root)) && abs_path($root) eq $root;
    die 'one host seed and 2..50 already admitted candidates required'
        unless ref($arg{anchors}) eq 'ARRAY' && @{$arg{anchors}} == 1
            && ref($arg{candidates}) eq 'ARRAY'
            && @{$arg{candidates}} >= 2 && @{$arg{candidates}} <= 50;
    # Caller-supplied generic host anchors are optional for the original
    # direct offline API. When supplied, bind the separate route token to
    # the trusted original Lyrion track BEFORE generating the immutable
    # exact-key artifact. Never claim a route token equals a file URL.
    my $host_anchors = $arg{host_anchors};
    die 'exactly one source host anchor required for bounded route binding'
        if defined($host_anchors)
            && (ref($host_anchors) ne 'ARRAY' || @$host_anchors != 1
                || ref($host_anchors->[0]) ne 'HASH');
    my $seed_binding = defined($host_anchors) ? $host_anchors->[0] : undef;
    die 'trusted absolute private workspace required'
        unless defined($arg{directory}) && !ref($arg{directory})
            && File::Spec->file_name_is_absolute($arg{directory})
            && -d $arg{directory} && !-l $arg{directory};

    my $private = tempdir('essentia-imported-pilot-XXXXXXXX',
        DIR => $arg{directory}, CLEANUP => 0);
    my $bundle;
    my $ok = eval {
        my $bliss = Plugins::EssentiaGuidance::BoundedSnapshot::open_source(
            $arg{bliss_db});
        my $sidecar = Plugins::EssentiaGuidance::BoundedSnapshot::open_source(
            $arg{feature_db});
        my ($validated) = $sidecar->selectrow_array(q{
            SELECT validated_against_essentia FROM feature_models
             WHERE model_key = ? COLLATE BINARY
        }, undef, $fingerprint);
        die 'missing or malformed original source validation flag'
            unless defined($validated) && "$validated" =~ /\A[01]\z/;
        die 'experimental model requires explicit preview opt-in'
            if !$validated && !$preview;

        my $stmt = $sidecar->prepare(q{
            SELECT t.model_key, t.audio_sha256, s.file_size,
                   s.model_key AS state_model_key
              FROM feature_tracks t
              JOIN feature_track_state s
                ON s.track_file = t.track_file COLLATE BINARY
               AND s.model_id = t.model_id COLLATE BINARY
             WHERE t.track_file = ? COLLATE BINARY
               AND t.model_id = ? COLLATE BINARY
        });
        my $check = Plugins::EssentiaGuidance::ExactIdentity::verifier_from_db_handles(
            $bliss, $sidecar);
        my $prefix = $root eq '/' ? '/' : "$root/";
        my $verify = sub {
            my ($key) = @_;
            die 'unsafe imported sidecar relative key'
                unless defined($key) && !ref($key) && length($key) <= 4096
                    && $key !~ m{(?:\A|/)\.\.?(?:/|\z)}
                    && $key !~ m{//} && $key !~ /\\/
                    && $key !~ m{\A/};
            die 'unmatched Bliss/sidecar file identity' unless $check->($key);
            my $full = File::Spec->catfile($root, split m{/}, $key);
            die 'missing or symlinked Pi audio source' if !-f $full || -l $full;
            my $resolved = abs_path($full);
            die 'local Pi source escapes configured music root'
                unless defined($resolved) && $resolved eq $full
                    && index($resolved, $prefix) == 0;
            $stmt->execute($key, $model);
            my $row = $stmt->fetchrow_hashref;
            die 'missing pinned scanner model feature/state' unless $row;
            die 'duplicate scanner feature state' if $stmt->fetchrow_hashref;
            die 'inconsistent imported model fingerprint or source hash'
                unless defined($row->{model_key})
                    && $row->{model_key} eq $fingerprint
                    && defined($row->{state_model_key})
                    && $row->{state_model_key} eq $fingerprint
                    && defined($row->{audio_sha256})
                    && $row->{audio_sha256} =~ /\A[a-f0-9]{64}\z/
                    && defined($row->{file_size})
                    && $row->{file_size} =~ /\A[1-9][0-9]*\z/;
            my $actual_size = -s $full;
            die 'Windows/Pi source file-size mismatch'
                unless defined($actual_size) && $actual_size == $row->{file_size};
            return 1;
        };

        my $artifact = Plugins::EssentiaGuidance::ExactIdentity::write_artifact(
            anchors => $arg{anchors}, candidates => $arg{candidates},
            media_dirs => [$root], verify_key => $verify,
            job_id => $arg{job_id}, directory => $private,
            (defined($seed_binding)
                ? (seed_anchor_binding => $seed_binding) : ()),
        );
        $stmt->finish;
        open my $fh, '<:raw', $artifact->{path}
            or die 'cannot reopen pinned exact key artifact';
        local $/;
        my $data = <$fh>;
        close $fh;
        die 'oversize identity artifact' if length($data) > 256 * 1024;
        my $rows = JSON::PP->new->utf8->decode($data)->{tracks};
        die 'incomplete admitted pilot cohort'
            unless ref($rows) eq 'ARRAY'
                && @$rows == 1 + @{$arg{candidates}};
        my $projection = File::Spec->catfile(
            $private, 'essentia-imported-feature-cohort.sqlite');
        Plugins::EssentiaGuidance::BoundedSnapshot::project_features(
            source_dbh => $sidecar, verified_tracks => $rows,
            model_id => $model, expected_model_key => $fingerprint,
            destination => $projection,
        );
        $bliss->do('ROLLBACK');
        $sidecar->do('ROLLBACK');
        $bliss->disconnect;
        $sidecar->disconnect;
        my $seed = $rows->[0];
        my @candidates = map {
            { candidate_id => $_->{track_id}, database_file => $_->{track_file} }
        } @$rows[1 .. $#$rows];
        $bundle = {
            private_directory => $private,
            job_id => $arg{job_id},
            artifacts => [$artifact],
            resources => [{
                kind => 'essentia-feature-sqlite-v3',
                path => $projection, access => 'read_only',
            }],
            options => {
                model_id => $model, metric => $metric,
                expected_model_key => $fingerprint,
                experimental_preview_opt_in => $preview
                    ? JSON::PP::true : JSON::PP::false,
            },
            anchors => [{
                anchor_id => $seed->{track_id},
                # In generic host mode the verified anchor token is seed-N,
                # but the track identity remains the original file URL.
                candidate_id => defined($seed_binding)
                    ? $seed_binding->{candidate_id} : $seed->{track_id},
                (defined($seed_binding)
                    ? (lms_urlmd5 => $seed_binding->{lms_urlmd5}) : ()),
                database_file => $seed->{track_file},
            }],
            context => {
                scope => 'global',
                left_anchor_id => undef, right_anchor_id => undef,
                context_track_ids => [$seed->{track_id}],
            },
            candidates => \@candidates,
            passive_only => JSON::PP::true,
            audit => {
                admitted_tracks => scalar(@$rows),
                host_route_bound => defined($seed_binding)
                    ? JSON::PP::true : JSON::PP::false,
                model_status => $validated ? 'validated' : 'experimental',
                source_bytes_verified => JSON::PP::false,
                catalog_generation_verified => JSON::PP::false,
                full_catalog_verified => JSON::PP::false,
            },
        };
        1;
    };
    unless ($ok) {
        eval { remove_tree($private) };
        die 'imported sidecar pilot rejected complete candidate cohort';
    }
    return $bundle;
}

1;
