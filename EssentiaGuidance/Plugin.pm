package Plugins::EssentiaGuidance::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);
use Plugins::EssentiaGuidance::Provider;

sub getDisplayName { return 'Bliss Guidance: Essentia (research)'; }

sub initPlugin {
    my $class = shift;
    return $class->SUPER::initPlugin(@_);
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
