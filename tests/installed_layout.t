use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

my $source = File::Spec->catdir($FindBin::Bin, '..', 'EssentiaGuidance');
my $stage = tempdir(CLEANUP => 1);
my $installed = File::Spec->catdir($stage, 'Plugins', 'EssentiaGuidance');
make_path($installed);
for my $file (qw(Plugin.pm Provider.pm Settings.pm strings.txt install.xml)) {
    copy(File::Spec->catfile($source, $file),
        File::Spec->catfile($installed, $file))
        or die "staging $file failed: $!";
}
unshift @INC, $stage;

{
    package Slim::Plugin::Base;
    sub import { }
    sub initPlugin { 1 }
    $INC{'Slim/Plugin/Base.pm'} = __FILE__;

    package Slim::Web::Settings;
    sub import { }
    sub new { return bless {}, $_[0] }
    $INC{'Slim/Web/Settings.pm'} = __FILE__;

    package Slim::Utils::Strings;
    our @paths;
    sub loadFile { push @paths, $_[0] }
    $INC{'Slim/Utils/Strings.pm'} = __FILE__;

    package main;
    sub WEBUI { 1 }
}

require Plugins::EssentiaGuidance::Plugin;
ok(Plugins::EssentiaGuidance::Plugin->initPlugin,
    'standard Lyrion plugin loads in the Plugins/EssentiaGuidance layout');
is(Plugins::EssentiaGuidance::Plugin->getDisplayName,
    'PLUGIN_ESSENTIAGUIDANCE_NAME', 'Lyrion plugin uses its localized name');
is(scalar(@Slim::Utils::Strings::paths), 1,
    'standard Lyrion strings are registered without network or scanner access');
ok(Plugins::EssentiaGuidance::Plugin->guidance_provider_descriptor_v1,
    'normal host can discover the provider descriptor');
ok(!Plugins::EssentiaGuidance::Plugin->guidance_provider_status_v1->{available},
    'even the installed and enabled plugin cannot become an active provider');
my $okay = eval {
    Plugins::EssentiaGuidance::Plugin->guidance_provider_native_spi_config_v1(
        { enabled => 1 }, { trusted => 1 },
    );
    1;
};
ok(!$okay, 'normal host config remains closed even after LMS installation');
is(Plugins::EssentiaGuidance::Settings->page,
    'plugins/EssentiaGuidance/settings/essentiaguidance.html',
    'settings page follows the standard Lyrion provider path');
my %params;
Plugins::EssentiaGuidance::Settings->beforeRender(\%params);
ok(!$params{provider_status}{available},
    'settings page renders only the unavailable passive status');
ok(!Plugins::EssentiaGuidance::Settings->can('prefs'),
    'settings page exposes no editable music roots, model paths or weights');

my $install = File::Spec->catfile($installed, 'install.xml');
open my $fh, '<', $install or die $!;
my $xml = do { local $/; <$fh> };
close $fh;
like($xml, qr{<module>Plugins::EssentiaGuidance::Plugin</module>},
    'install descriptor references actual staged plugin module');
like($xml, qr{<minVersion>8\.5</minVersion>},
    'install descriptor declares supported Lyrion minimum');
for my $platform (qw(mac win other)) {
    like($xml, qr{<$platform>disabled</$platform>},
        "$platform installation defaults disabled");
}
my $html = File::Spec->catfile($source, qw(HTML EN plugins EssentiaGuidance settings essentiaguidance.html));
ok(-f $html, 'status-only HTML page is shipped in conventional layout');
my $html_text;
{ open my $fh, '<', $html or die $!; local $/; $html_text = <$fh>; }
unlike($html_text, qr{<input|<button|<form|javascript:}i,
    'status page has no browser action to launch a probe or enable scoring');

done_testing();
