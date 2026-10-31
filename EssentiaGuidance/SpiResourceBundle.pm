package Plugins::EssentiaGuidance::SpiResourceBundle;

use strict;
use warnings;

use File::Path qw(remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Plugins::EssentiaGuidance::ExactIdentity ();
use Plugins::EssentiaGuidance::BoundedSnapshot ();

# OFFLINE RESEARCH FIXTURE ONLY, not a Lyrion provider entry point.
# It demonstrates composition of provider-owned source verification and
# standard SPI-v2 artifacts/resources. It does NOT prove joint generation
# or multi-root provenance, and Provider.pm MUST keep production unavailable.
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
        my $verify = Plugins::EssentiaGuidance::ExactIdentity::verifier_from_db_handles(
            $bliss, $features);
        my $artifact = Plugins::EssentiaGuidance::ExactIdentity::write_artifact(
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
        my @rows = @{$decoded->{tracks}};
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

        $bliss->do('ROLLBACK');
        $features->do('ROLLBACK');
        $verify = undef;
        $bliss->disconnect;
        $features->disconnect;

        my $seed = $rows[0];
        my @candidates = map {
            { candidate_id => $_->{track_id}, database_file => $_->{track_file} }
        } @rows[1 .. $#rows];
        $result = {
            private_directory => $private,
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
