# Changelog

## Unreleased

- `PreparationPolicy.videoConcurrency` (default 1, every built-in policy):
  videos prepare one at a time app-wide, beside `concurrency` (2) for all
  items; a video holds a slot of each and a still or file behind a waiting
  video goes ahead.
- `CaptureMediaPreparation`: `mpx_core`'s `MediaPreparation` over a
  `MediaPreparer` and a policy, so the limits hold for every caller. It
  writes the thumbnail as a file beside the outputs
  (`PreparedMedia.thumbnailPath`); `MediaPreparer.prepare` takes
  `thumbnailFile` for the same.
- Diagnostics: `PreparationOp` (category `preparation`: `queued`, `started`,
  `progress`, `finished`, `failed`, `cancelled`) through
  `MpxDiagnostics.current`.
- `PreparationInput`, `PreparationIntent`, `CompressionPreset`,
  `PreparedKind` and `PreparedMedia` moved to `mpx_core`, which a host now
  imports them from; this package no longer exports them.
  `CompressionPreset.planFor` stays here, as the `CompressionPresetPlan`
  extension.
- `CameraCaptureSurface.show` completes when the page is gone, after its
  close transition, not at the pop: the page keeps building through the
  close. A host that frees what it handed the page when `show` returns
  (the strip's gallery) no longer frees it while the page still uses it.
- The system back waits while a photo is taken, as the close button, the
  switch and a dismiss drag already did: a burst then a back no longer
  closes the page under a photo still in flight. The page closes on the
  next back.
- The camera page's strip lists the host's album after the shots
  (`CameraCaptureSurface.gallery`, a lazy `CaptureStripGallery`), each item
  with its picture, a video's duration and its selection number
  (`galleryOrder`, `onGalleryToggle`). The route carries the host's asset
  cache for those pictures.
- The snapshot is blurred once into a picture of its own, so the turning
  card draws a plain image: a blur filter under the turn's perspective was
  drawn unevenly from frame to frame, flashing a flatter, sharper card. A
  switched camera's frames that come back while the card turns wait for the
  turn to end before they fade in, so they never turn with it.
- The switch and pause snapshot is read from the bare frames and shown
  through the turn, mirror and fit they had, so the card shows the crop the
  user saw (a raster of the fitted preview held the texture whole, a
  differently framed picture that jumped at the top and bottom).
- Android records the preview's own frames: a GL thread draws each camera
  frame into the Flutter surface and, while recording, into an H.264
  encoder (3.5 Mbit/s from 720 lines, 1.8 below; AAC 32 kbit/s), so a
  recording never changes the camera's session and the preview never
  stalls; the VideoCapture use case is gone and `prepareVideo` /
  `releaseVideo` have nothing to do there. A hold let go while its
  recording is still starting stops the recording once it has started.
- `CameraShot.thumbnailPath`: a lasting picture of each shot (a recording's
  poster, a photo's 240 wide PNG written beside it), so a camera page opened
  again draws the kept shots of an earlier one.
- `CameraSession.prepareVideo` / `releaseVideo`: the full camera page keeps
  the camera ready to record while it shows, so a recording starts on the
  running session (on Android the video use case is bound with the preview
  and photos in one session; binding it at the start closed and reopened
  the session and stalled the preview). The switch turn's perspective is
  four heights deep, so the turning card stays near the preview's size.
- The kept shots strip draws the usual cell (80 square, 6 apart, a
  recording's duration pill, the selection check and number;
  `shotOrder`, `onShotToggle`, `shotSelection`) with a picture of each
  shot: a photo's own, a recording's first frame
  (`CaptureOutput.posterPath`, a small JPEG the platform writes beside the
  video).
- A camera switch turns one card: while it turns, only the snapshot is
  drawn (the live frames under it, mirrored and shaped differently, no
  longer show at its edges).
- The kept shots under `$Android` (`shotsCounter`): with
  `CameraCaptureSurface(shots:, onShotsTap:)` and
  `CaptureSurfaceLabels.shotsCount`, a strip of 80 tiles at the bottom
  (`resultBuilder`) and a counter button ("3 PHOTOS") that opens them; the
  shutter row moves up 96.
- The capture surface closes with a vertical swipe: past 25 px the preview
  follows the finger and the controls fade (220 ms); released past a sixth
  of the height it closes from there into the slot, otherwise it comes back
  (250 ms, decelerating).
- Input guards: a camera switch asked for while one runs
  is ignored (until the new camera's first frame); the switch and close
  wait for a photo being taken; the flash icon swaps over 220 ms and taps
  meanwhile are ignored; `CameraCaptureSurface.show` opens one surface per
  session; under `$IOS` (`locksWhileSwitching`) every control waits for a
  switch. `FakeCameraSessions(photoTakes:)` and `FakeCameraSession.switches`.
- Android frames and photos take the screen's shape (16:9 unless the screen
  is within 0.1 of 4:3): preview 1280 wide, photos up to 1920 x 1080 from
  the back camera and 1280 x 720 from the front. A `CameraPreview` under
  another page no longer plays a switch made there when it shows again.
  The zoom knob is 12 across (16.7 pressed).
- `CaptureSurfacePolicy` (`$Android`, `$IOS`, `forPlatform`) on
  `CameraCaptureSurface(policy:)`. `$IOS`:
  - a Video / Photo mode control (`CaptureSurfaceLabels.videoMode` /
    `photoMode`); a 250 ms hold in photo mode moves to video and records;
  - flash off / auto;
  - lens buttons and factor zoom (pinch, a drag up from the recording
    shutter) up to 8×, back to 1× 0.3 s after a recording;
  - a focus crosshair with an exposure drag;
  - a shutter that turns into a red square while recording;
  - a red `MM:SS` timer;
  - close, flash, switch and modes fading while recording;
  - a photo blink;
  - a results strip (`resultBuilder`, `onShotRemoved`).
- Zoom factors, lenses and exposure on the camera session:
  `CameraSessionValue.zoomFactor` / `minZoomFactor` / `maxZoomFactor` /
  `lenses` / `exposure` / `hasExposure`, `CameraSession.setZoomFactor` and
  `setExposure`; `CameraZoom` relates the 0..1 zoom to factors. On iPhone the
  back camera is the virtual device that joins its lenses (1x the main
  lens); on Android the zoom is CameraX's ratio. A switch starts the new
  camera at 1x.
- The capture surface's zoom slider: 50 high, 126 above the bottom, shown
  (180 ms fade) whenever the zoom is used and hidden 2 s after; its knob
  drags the zoom, a tap on its track jumps there, minus and plus step a
  quarter over 180 ms. A held shutter dragged above its top zooms by the
  distance over 200, back to the widest when it comes down.
- `CameraSession.requestMicrophone` and `CameraSessionValue.microphone`
  (`MicrophoneAccess`): a grant mid-session gives the next recording sound.
  `CameraCaptureSurface.onVideoRefused` (`CaptureVideoRefusal`) tells the
  host of a hold on a surface for photos only and of a refused microphone;
  with `videoNeedsMicrophone` (default) a hold without the microphone asks
  for it and records nothing.
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
