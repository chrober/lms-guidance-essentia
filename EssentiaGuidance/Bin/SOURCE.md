# Native executable provenance — research-only

No native executable is committed or bundled in this repository. A local
staging installation may place an independently built, version-pinned
`bliss-guidance-essentia` executable here **only after** checking its
platform architecture, source commit, executable version and third-party
licensing. Do not publish/download an unreviewed executable automatically.

The canonical native source for this plugin is
[bliss-guidance-essentia](https://github.com/chrober/bliss-guidance-essentia).
The current tested research revision is
`ed9443725b9112203cb10d72a3efd65de79859ed` and uses Guidance SPI v2.

Normal `Provider::guidance_provider_status_v1` remains unavailable and
`guidance_provider_native_spi_config_v1` always rejects, even if an
executable is placed here. The standalone passive offline probe uses an
explicit local executable path and never installs/runs an LMS rescan hook.

This repository does not publish an LMS plugin release archive or LMS
plugin-repository entry. Installation testing must use an isolated staging
Lyrion instance and this research branch only.
