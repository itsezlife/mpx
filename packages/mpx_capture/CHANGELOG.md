# Changelog

## Unreleased

- `CameraSlotPreview`: the small preview of a camera session for a grid's
  camera slot (30 fps cap, pauses on the slot's signal, an allow-access
  state, unavailable sessions reported); `CameraCaptureSurface.show(from:)`
  expands from the slot over 350 ms on the same session.
- `WebPreparationCodec`: still preparation on the web (object URLs in,
  JPEGs in memory out, `PreparedMedia.bytes`); `PreparationInput.byteSize`.
- Camera session: `CameraSessions.open` (one session per process) gives a
  preview texture, photos, videos, a camera switch, a flash mode, pause and
  resume, and a frame-rate cap for small previews; `CameraPreview` shows
  it; `CameraCaptureSurface` is the minimal full-screen camera (tap for a
  photo, hold for a video, switch, flash, close) that takes the running
  session over and gives it back without a restart, putting shots into the
  bytes store under `MediaKey.local`. `PlatformCameraSessions`: CameraX on
  Android, AVCaptureSession on iOS and macOS.
- One camera owner per process across camera sessions and round video:
  opening either takes the camera over from the other.
- `testing.dart`: `FakeCameraSessions`, `FakeCamera`,
  `CameraSessionContract` and `CameraOwnershipContract`.
- Media preparation: `MediaPreparer.prepare(input, intent, policy)` makes a
  picked item ready to upload (stills scaled and encoded, videos
  compressed or passed through, thumbnails, facts), two at a time, with
  progress and cancel. `PreparationPolicy.$Android`, `$IOS`, `$Desktop`
  and `$Web` hold each platform's sizes, JPEG qualities, thumbnails and
  video offers. `PlatformPreparationCodec` reads and encodes stills on
  Android, iOS and macOS.
- `CompressionPreset.tiny`: the 432 px step (at most 750 kbps), offered by
  the Android policy only. `CompressionPreset.offeredFor` keeps offering the
  five shared steps (`CompressionPreset.shared`).
- `testing.dart`: `FakePreparationCodec` and `PreparationCodecContract`.
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
