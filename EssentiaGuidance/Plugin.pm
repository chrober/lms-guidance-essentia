package Plugins::EssentiaGuidance::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);
use Plugins::EssentiaGuidance::Provider;
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);

sub getDisplayName { return 'PLUGIN_ESSENTIAGUIDANCE_NAME'; }

sub initPlugin {
    my $class = shift;
    _load_strings();
    if (main::WEBUI) {
        require 'Plugins/EssentiaGuidance/Settings.pm';
        Plugins::EssentiaGuidance::Settings->new;
    }
    return $class->SUPER::initPlugin(@_);
}

sub _load_strings {
    my $path = catfile(dirname(__FILE__), 'strings.txt');
    return unless -r $path;
    eval {
        require Slim::Utils::Strings;
        Slim::Utils::Strings::loadFile($path);
    };
}

sub guidance_provider_descriptor_v1 {
    return Plugins::EssentiaGuidance::Provider::guidance_provider_descriptor_v1();
}

sub guidance_provider_defaults_v1 {
    return Plugins::EssentiaGuidance::Provider::guidance_provider_defaults_v1();
}

sub guidance_provider_status_v1 {
    return Plugins::EssentiaGuidance::Provider::guidance_provider_status_v1();
}

sub guidance_provider_native_spi_config_v1 {
    shift;
    return Plugins::EssentiaGuidance::Provider::guidance_provider_native_spi_config_v1(@_);
}

1;
