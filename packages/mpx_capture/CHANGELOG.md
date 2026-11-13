# Changelog

## Unreleased

- Android fixes from device runs: compressed files no longer carry a
  400 KB reserved head (the index goes at the end); a source that fits is
  remuxed; cancelling a recording returns once its file is deleted.
  `CaptureProgress.bytesWritten` is 0 while Android compresses.
- Round video on Android: frames stand upright when the camera writes its
  orientation into the buffer, and the microphone is timed on the camera's
  clock (sound was dropped after the device had slept).
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
- Capture output into the cache: `CaptureCache` mints `MediaKey.local`
  keys, moves the output into an `IBytesStore` (in pieces, as a complete
  ranged resource, where the store keeps ranges), aliases the server key
  after upload and releases the local key on confirm.
- `testing.dart`: `FakeTranscoder`, `TranscoderContract`,
  `FakeRoundVideoRecorder`, `RoundVideoRecorderContract`.
- Example app that compresses a bundled clip and records a round video.

## 0.0.1

- Initial package skeleton.
