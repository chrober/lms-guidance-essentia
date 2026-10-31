use strict;
use warnings;
use File::Spec;
use FindBin;
use Test::More;

BEGIN {
    package Slim::Plugin::Base;
    sub initPlugin { 1 }
    $INC{'Slim/Plugin/Base.pm'} = __FILE__;

    package Slim::Utils::PluginManager;
    sub enabledPlugins { return ('Plugins::EssentiaGuidance::Plugin') }
    $INC{'Slim/Utils/PluginManager.pm'} = __FILE__;
}

use lib "$FindBin::Bin/..";
require 'EssentiaGuidance/Provider.pm';
$INC{'Plugins/EssentiaGuidance/Provider.pm'} =
    $INC{'EssentiaGuidance/Provider.pm'};
require 'EssentiaGuidance/Plugin.pm';

my $host = $ENV{ESSENTIA_SHARED_HOST_SRC} || '';
plan skip_all => 'pinned generic host checkout is required'
    unless $host && -f File::Spec->catfile(
        $host, 'Plugins', 'BlissGuidance', 'Discovery.pm');
my $discovery_path = File::Spec->catfile(
    $host, 'Plugins', 'BlissGuidance', 'Discovery.pm');
require $discovery_path;

my $discovery = Plugins::BlissGuidance::Discovery::discover();
is(scalar(@{$discovery->{providers}}), 1,
    'generic host discovers normally installed Essentia plugin');
my $entry = $discovery->{providers}[0];
is($entry->{provider_id}, 'essentia',
    'descriptor retains stable independent provider identity');
is($entry->{module}, 'Plugins::EssentiaGuidance::Plugin',
    'no hard-coded Essentia branch in shared host');
ok(!$entry->{available},
    'generic discovery must never activate a research-only Essentia install');
is($entry->{diagnostic},
    'source_generation_and_root_provenance_unverified',
    'normal generic discovery exposes the actual outstanding trust gate');
is($entry->{status}{available}, 0,
    'normal source status stays unavailable even if plugin loads');
is_deeply($entry->{descriptor}{controls}, [],
    'no browser-accessible host influence control exists');
my $config_allowed = eval {
    Plugins::BlissGuidance::Discovery::native_spi_config(
        $entry, {}, {research_only => 1, passive_only => 1});
    1;
};
ok(!$config_allowed, 'shared host refuses native config even with forged research flags');
my $acquired;
my $allowed = eval {
    Plugins::BlissGuidance::Discovery::acquire_artifacts(
        $entry, {}, {}, sub { $acquired = shift });
    1;
};
ok(!$allowed, 'shared host refuses artifact acquisition while provider is unavailable');
ok(!defined($acquired), 'unavailable provider never passes artifacts to a callback');
done_testing();
