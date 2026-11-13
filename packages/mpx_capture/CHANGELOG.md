# Changelog

## Unreleased

- Compression before send: `CompressionPreset` (the shared size / kbps
  table and its plan), `Transcoder` with `PlatformTranscoder` (Media3
  Transformer on Android, AVAssetReader into AVAssetWriter on iOS and
  macOS), `CaptureJob` with `CaptureProgress` (bytes written, final size,
  header rewritten) and cancel.
- `testing.dart`: `FakeTranscoder`, `TranscoderContract`.
- Example app that compresses a bundled clip.

## 0.0.1

- Initial package skeleton.
