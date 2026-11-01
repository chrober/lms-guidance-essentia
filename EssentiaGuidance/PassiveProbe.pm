package Plugins::EssentiaGuidance::PassiveProbe;

use strict;
use warnings;

use File::Path qw(remove_tree);
use File::Spec;
use Plugins::EssentiaGuidance::ImportedSidecarPilot ();

# Manual, in-process, **offline research** entrypoint. The normal discovery
# provider factory remains unavailable, and no settings/UI action invokes
# this code. Only trusted local Perl code with actual Lyrion track objects
# may supply the full, explicitly bounded cohort.
#
# There is deliberately no native JSONL implementation here: use the shared,
# existing provider-neutral Guidance SPI v2 runtime.
sub run {
    my (%arg) = @_;
    die 'manual passive research opt-in is required'
        unless defined($arg{research_only}) && !ref($arg{research_only})
            && "$arg{research_only}" eq '1'
            && defined($arg{passive_only}) && !ref($arg{passive_only})
            && "$arg{passive_only}" eq '1';
    die 'exactly one generic host source anchor is required'
        unless ref($arg{host_anchors}) eq 'ARRAY'
            && @{$arg{host_anchors}} == 1;
    my $program = $arg{native_program};
    die 'trusted absolute executable is required'
        unless defined($program) && !ref($program)
            && File::Spec->file_name_is_absolute($program)
            && -f $program && -x $program && !-l $program;
    my $deadline = $arg{deadline_ms};
    $deadline = 5000 unless defined $deadline;
    die 'bounded passive probe deadline required'
        unless !ref($deadline) && "$deadline" =~ /\A[1-9][0-9]{0,4}\z/
            && $deadline >= 100 && $deadline <= 10000;

    my ($bundle, $result, $cleanup_ok);
    my $ok = eval {
        $bundle = Plugins::EssentiaGuidance::ImportedSidecarPilot::assemble_pilot_bundle(
            %arg,
        );
        # Deliberately late-load the shared host: it is an optional external
        # plugin dependency and is never a bundled Essentia subprocess runner.
        require Plugins::BlissGuidance::Runtime;
        $result = Plugins::BlissGuidance::Runtime::score_batch({
            id => 'essentia-guidance',
            program => $program,
            options => $bundle->{options},
            artifacts => $bundle->{artifacts},
            resources => $bundle->{resources},
            timeout_ms => $deadline,
        }, {
            job_id => $bundle->{job_id},
            request_id => 'manual-passive-essentia-pilot',
            deadline_ms => $deadline,
            anchors => $bundle->{anchors},
            context => $bundle->{context},
            candidates => $bundle->{candidates},
        });
        die 'generic host did not complete the native session'
            unless ref($result) eq 'HASH' && $result->{valid}
                && ref($result->{manifest}) eq 'HASH'
                && ($result->{manifest}{provider_id} || '') eq 'essentia-guidance'
                && ref($result->{prepared}) eq 'HASH'
                && ($result->{prepared}{type} || '') eq 'prepared'
                && ref($result->{signals}) eq 'ARRAY'
                && @{$result->{signals}} == 0
                && ref($result->{diagnostics}) eq 'HASH'
                && ($result->{diagnostics}{state} || '')
                    eq 'shadow_evaluated_no_active_signals';
        1;
    };
    # Removing private SHA-256 artifacts and bounded SQLite projection is
    # mandatory even after invalid native responses or a host timeout.
    if (ref($bundle) eq 'HASH' && $bundle->{private_directory}) {
        my $dir = $bundle->{private_directory};
        $cleanup_ok = eval { remove_tree($dir); !-e $dir };
    } else {
        $cleanup_ok = 1;
    }
    return {
        valid => 0, signals => [], state => 'passive_probe_failed',
    } unless $ok && $cleanup_ok;
    return {
        valid => 1,
        signals => [],
        state => 'shadow_evaluated_no_active_signals',
        candidate_count => scalar(@{$bundle->{candidates}}),
        model_status => $bundle->{audit}{model_status},
        host_route_bound => $bundle->{audit}{host_route_bound} ? 1 : 0,
        source_bytes_verified => 0,
        catalog_generation_verified => 0,
        full_catalog_verified => 0,
    };
}

1;
