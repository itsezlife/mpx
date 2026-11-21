# Changelog

## Unreleased

- A camera session lets the camera go while the app is hidden (another
  app may take it) and opens it again when the app shows, unless the host
  paused it meanwhile; a recording stops first, and the previews hold
  their last frame, blurred, until frames return.
- `CameraSession.capturePhoto(mirrorFront:)` saves a front camera's photo
  mirrored, as its preview shows it; `CameraCaptureSurface` does so by
  default (`mirrorFrontPhotos`). Videos stay unmirrored. The zoom returns
  to the widest after each shot. A hold records after 800 ms
  (`CameraCaptureSurface.holdToRecord`); a pressed shutter grows to 1.06.
  While recording, the flash and the switch slide out to their edge and
  fade (150 ms).
- `CameraSession.setZoom` (linear 0..1, `CameraSessionValue.zoom`) and
  `focusAt` (a point of the preview). The capture surface focuses where the
  picture is tapped (a closing ring), zooms with two fingers, and counts a
  recording's seconds in a pill at the top.
- `CameraPreview` covers a pause and a switch with the last frame the user
  saw, a small snapshot taken before the frames stop (80 px wide for a
  pause, 100 for a switch), blurred and never flipped; it fades out as the
  frames come back (180 ms after a resume, 120 ms after a switch).
  `CameraSessionValue.awaitingFrames`. The capture surface expands from the
  slot over 350 ms and collapses over 220 ms on an ease curve, its
  controls fading with it.
- Android: the camera session binds preview and photos only; the video
  use case and its encoder join when a recording starts and leave when it
  ends, so browsing with a live camera cell builds no encoder.
- A camera switch no longer shows the old camera's frames mirrored or
  turned as the new camera's: `CameraSessionValue.isSwitching` holds from
  the switch until the platform reports the new camera's first frame, and
  `CameraPreview` draws the frames as before, blurred and turning over,
  until then.
- `CameraSlotPreview`: the small preview of a camera session for a grid's
  camera slot (30 fps cap, pauses on the slot's signal, an allow-access
  state, unavailable sessions reported); `CameraCaptureSurface.show(from:)`
  expands from the slot over 350 ms on the same session: only the preview
  morphs; the controls are laid out at the whole screen and fade in after
  the expand (150 ms) and out before the collapse.
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
