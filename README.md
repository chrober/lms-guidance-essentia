# Bliss Guidance: Essentia (Lyrion provider)

**Status: installation/integration design only; no installable functional plugin is shipped or activated.**

A future independently installable, passive Lyrion guidance provider, following the conventions of [`lms-guidance-lastfm`](https://github.com/chrober/lms-guidance-lastfm) and [`lms-guidance-library-signals`](https://github.com/chrober/lms-guidance-library-signals). It will expose an optional [`bliss-guidance-essentia`](https://github.com/chrober/bliss-guidance-essentia) native provider using the host-independent [`essentia-similarity`](https://github.com/chrober/essentia-similarity) engine to compatible Lyrion hosts: [BlissMixerLab](https://github.com/chrober/lms-blissmixer-lab) first, then [Better Call Bliss](https://github.com/chrober/lms-better-call-bliss).

Lyrion hosts discover installed guidance providers, keep them opt-in, resolve trusted configuration and invoke native hosts implementing the [`bliss-playlist-guidance-spi`](https://github.com/chrober/bliss-playlist-guidance-spi) version 2. This plugin must **not** modify an already-playing queue, accept unauthorized database paths from browser input, fetch ONNX models during playback, or bypass Bliss admission/repeat/route constraints.

This repository is the Lyrion configuration/packaging surface, **not the provider-side Rust scoring implementation**. Consult [integration and acceptance contract](docs/lyrion-provider-contract.md) before implementation. Start from [`lms-bliss-guidance-provider-kit`](https://github.com/chrober/lms-bliss-guidance-provider-kit) and the current working Library Signals provider rather than reinventing discovery or settings UI.
