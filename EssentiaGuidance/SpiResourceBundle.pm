package Plugins::EssentiaGuidance::SpiResourceBundle;

use strict;
use warnings;

use File::Path qw(remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Plugins::EssentiaGuidance::ExactIdentity ();
use Plugins::EssentiaGuidance::BoundedSnapshot ();
use Plugins::EssentiaGuidance::SourceProvenance ();
use Plugins::EssentiaGuidance::CatalogFingerprint ();

# OFFLINE RESEARCH FIXTURE ONLY, not a Lyrion provider entry point.
# It demonstrates composition of provider-owned source verification and
# standard SPI-v2 artifacts/resources. It does NOT prove joint generation
# or any joint catalogue generation. A content-attested cohort can prove
# exact file bytes across multiple roots without proving global scan sync.
# Provider.pm MUST keep production unavailable.
# The caller owns and must remove private_directory after the SPI session.
sub assemble_research_bundle {
    my (%arg) = @_;
    die 'research-only explicit opt-in required'
        unless defined($arg{research_only}) && !ref($arg{research_only})
            && "$arg{research_only}" eq '1';
    die 'host root of private temporary directory required'
        unless defined($arg{directory}) && !ref($arg{directory})
            && File::Spec->file_name_is_absolute($arg{directory})
            && -d $arg{directory} && !-l $arg{directory};
    die 'invalid model/metric'
        unless defined($arg{model_id}) && !ref($arg{model_id})
            && $arg{model_id} =~ /\A(?:genre|moodtheme)\z/
            && defined($arg{metric}) && !ref($arg{metric})
            && $arg{metric} =~ /\A(?:affine_cosine_v1|affine_centered_cosine_v1)\z/;
    die 'invalid model fingerprint'
        unless defined($arg{expected_model_key})
            && !ref($arg{expected_model_key})
            && $arg{expected_model_key} =~ /\A[A-Za-z0-9._:-]{1,128}\z/;
    die 'invalid experimental preview flag'
        if defined($arg{experimental_preview_opt_in})
            && (ref($arg{experimental_preview_opt_in})
                || $arg{experimental_preview_opt_in} !~ /\A[01]\z/);

    my $private = tempdir('essentia-provider-XXXXXXXX',
        DIR => $arg{directory}, CLEANUP => 0);
    my $result;
    my $ok = eval {
        my $bliss = Plugins::EssentiaGuidance::BoundedSnapshot::open_source(
            $arg{bliss_db});
        my $features = Plugins::EssentiaGuidance::BoundedSnapshot::open_source(
            $arg{feature_db});
        my $catalog_proof;
        if (exists $arg{catalog_roots}) {
            die 'catalog proof requires original-file SHA256 audit'
                unless $arg{verify_audio_content};
            die 'catalog proof requires explicit matching music root mapping'
                unless ref($arg{catalog_roots}) eq 'ARRAY'
                    && ref($arg{media_dirs}) eq 'ARRAY'
                    && @{$arg{catalog_roots}} == @{$arg{media_dirs}};
            my %wanted = map { $_ => 1 } @{$arg{media_dirs}};
            for my $root (@{$arg{catalog_roots}}) {
                die 'invalid or mismatched music root mapping'
                    unless ref($root) eq 'HASH'
                        && defined($root->{host_path})
                        && exists($wanted{$root->{host_path}})
                        && delete($wanted{$root->{host_path}});
            }
            die 'not all configured roots were mapped' if %wanted;
            $catalog_proof = Plugins::EssentiaGuidance::CatalogFingerprint::snapshot(
                research_only => 1, bliss_dbh => $bliss,
                roots => $arg{catalog_roots},
            );
        }
        my ($artifact, @rows, $content_proof);
        if ($arg{verify_audio_content}) {
            # Offline-only full SHA256 of original audio, checked against
            # scanner feature_tracks.audio_sha256 and feature_track_state.
            # Supports different configured music roots only where the
            # relative scanner keys remain globally collision-free.
            $content_proof = Plugins::EssentiaGuidance::SourceProvenance::attest_cohort(
                research_only => 1,
                anchors => $arg{anchors}, candidates => $arg{candidates},
                media_dirs => $arg{media_dirs},
                bliss_dbh => $bliss, feature_dbh => $features,
                model_id => $arg{model_id},
                expected_model_key => $arg{expected_model_key},
                (defined($arg{max_file_bytes})
                    ? (max_file_bytes => $arg{max_file_bytes}) : ()),
                (defined($arg{max_total_bytes})
                    ? (max_total_bytes => $arg{max_total_bytes}) : ()),
            );
            @rows = @{$content_proof->{tracks}};
            $artifact = Plugins::EssentiaGuidance::ExactIdentity::write_content_attested_artifact(
                research_only => 1, proof => $content_proof,
                job_id => $arg{job_id}, directory => $private,
            );
        } else {
            # Historical exact-key proof: at most one music root, without
            # verifying whether scanner feature rows match current audio.
            my $verify = Plugins::EssentiaGuidance::ExactIdentity::verifier_from_db_handles(
                $bliss, $features);
            $artifact = Plugins::EssentiaGuidance::ExactIdentity::write_artifact(
                anchors => $arg{anchors}, candidates => $arg{candidates},
                media_dirs => $arg{media_dirs}, verify_key => $verify,
                job_id => $arg{job_id}, directory => $private,
                windows => $arg{windows},
            );
            open my $fh, '<:raw', $artifact->{path}
                or die 'cannot read bounded identity artifact';
            local $/;
            my $blob = <$fh>;
            close $fh;
            die 'oversize identity artifact' if length($blob) > 256 * 1024;
            my $decoded = JSON::PP->new->utf8->decode($blob);
            @rows = @{$decoded->{tracks}};
        }
        die 'incomplete exact identity cohort'
            unless @rows == 1 + @{$arg{candidates}};

        my $projected = File::Spec->catfile(
            $private, 'essentia-feature-bounded.sqlite');
        Plugins::EssentiaGuidance::BoundedSnapshot::project_features(
            source_dbh => $features, verified_tracks => \@rows,
            model_id => $arg{model_id},
            expected_model_key => $arg{expected_model_key},
            destination => $projected,
        );

        # A pinned WAL read is not a freshness check: always open a new,
        # independent read transaction after resource preparation.
        if ($catalog_proof) {
            Plugins::EssentiaGuidance::CatalogFingerprint::assert_fresh(
                research_only => 1, expected => $catalog_proof,
                bliss_db => $arg{bliss_db}, roots => $arg{catalog_roots},
            );
        }
        $bliss->do('ROLLBACK');
        $features->do('ROLLBACK');
        $bliss->disconnect;
        $features->disconnect;

        my $seed = $rows[0];
        my @candidates = map {
            { candidate_id => $_->{track_id}, database_file => $_->{track_file} }
        } @rows[1 .. $#rows];
        $result = {
            private_directory => $private,
            ($catalog_proof ? (catalog_fingerprint => {
                kind => $catalog_proof->{kind},
                fingerprint_sha256 => $catalog_proof->{fingerprint_sha256},
                catalog_sha256 => $catalog_proof->{catalog_sha256},
                host_root_map_sha256 => $catalog_proof->{host_root_map_sha256},
                eligible_tracks => $catalog_proof->{eligible_tracks},
                generation_verified => JSON::PP::false,
            }) : ()),
            ($content_proof ? (audio_content_audit => {
                verified_count => $content_proof->{verified_count},
                music_root_count => $content_proof->{music_root_count},
                bytes_hashed => $content_proof->{bytes_hashed},
                generation_verified => JSON::PP::false,
            }) : ()),
            options => {
                model_id => $arg{model_id}, metric => $arg{metric},
                expected_model_key => $arg{expected_model_key},
                experimental_preview_opt_in =>
                    $arg{experimental_preview_opt_in}
                        ? JSON::PP::true : JSON::PP::false,
            },
            artifacts => [$artifact],
            resources => [{
                kind => 'essentia-feature-sqlite-v3',
                path => $projected, access => 'read_only',
            }],
            anchors => [{
                anchor_id => $seed->{track_id},
                candidate_id => $seed->{track_id},
                database_file => $seed->{track_file},
            }],
            context => {
                scope => 'global', left_anchor_id => undef,
                right_anchor_id => undef,
                context_track_ids => [$seed->{track_id}],
            },
            candidates => \@candidates,
            job_id => $arg{job_id},
        };
        1;
    };
    unless ($ok) {
        # No part of a failed identity/feature cohort may reach SPI.
        eval { remove_tree($private) };
        die 'provider research SPI bundle failed closed';
    }
    return $result;
}

1;
