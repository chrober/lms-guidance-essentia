package Plugins::EssentiaGuidance::Settings;

use strict;
use warnings;
use base qw(Slim::Web::Settings);
use Plugins::EssentiaGuidance::Provider;

# Status-only page. It deliberately does not expose editable paths, model
# settings or a start/probe action to the browser, and cannot enable scoring.
sub name {
    return 'PLUGIN_ESSENTIAGUIDANCE_NAME';
}

sub page {
    return 'plugins/EssentiaGuidance/settings/essentiaguidance.html';
}

sub beforeRender {
    my ($class, $params) = @_;
    $params->{provider_status} =
        Plugins::EssentiaGuidance::Provider::guidance_provider_status_v1();
}

1;
