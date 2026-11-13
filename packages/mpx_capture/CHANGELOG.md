# Changelog

## Unreleased

- Compression before send: `CompressionPreset` (the shared size / kbps
  table and its plan), `Transcoder` with `PlatformTranscoder` (Media3
  Transformer on Android, AVAssetReader into AVAssetWriter on iOS and
  macOS), `CaptureJob` with `CaptureProgress` (bytes written, final size,
  header rewritten) and cancel.
- Round video messages on iOS and macOS: `RoundVideoRecorder` with
  `PlatformRoundVideoRecorder` (AVCaptureSession into AVAssetWriter),
  `RoundVideoConfig`, `RoundVideoRecording` (pause, resume, camera switch,
  stop) and `RoundVideoPreview`.
- Round video messages on Android: CameraX preview through a GL stage
  (centre square, upright, front camera mirrored) into a MediaCodec H.264
  encoder, AudioRecord into AAC, MediaMuxer; `CAMERA` and `RECORD_AUDIO`
  in the package manifest.
- `testing.dart`: `FakeTranscoder`, `TranscoderContract`,
  `FakeRoundVideoRecorder`, `RoundVideoRecorderContract`.
- Example app that compresses a bundled clip and records a round video.

## 0.0.1

- Initial package skeleton.
