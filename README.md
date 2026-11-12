# mpx

Portable media for Flutter apps: an HTTP bytes cache, a media core with an
asset pipeline and decoders, a hardware video player, an optional viewer and
capture, and a composition root that wires them.

Work in progress: the packages are being filled ticket by ticket. Nothing is
published yet.

## Packages

| Package | What it is |
| --- | --- |
| [`http_bytes_cache`](packages/http_bytes_cache) | Durable HTTP bytes cache, pure Dart |
| [`mpx_core`](packages/mpx_core) | Media identity, asset cache, decode pipeline, texture hosts |
| [`mpx_lottie`](packages/mpx_lottie) | Vector animation decoder |
| [`mpx_video_decoder`](packages/mpx_video_decoder) | Software decoder for silent video loops |
| [`mpx_player`](packages/mpx_player) | Hardware video player and feed playback |
| [`mpx_ui`](packages/mpx_ui) | Optional fullscreen viewer and feed widgets |
| [`mpx_capture`](packages/mpx_capture) | Optional compression and round video |
| [`mpx`](packages/mpx) | Composition root |

## Docs

- [Spec](docs/spec.md)
- [Architecture decisions](docs/adr/)
