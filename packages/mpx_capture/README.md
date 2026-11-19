# mpx_capture

Optional media capture for mpx: compression before send against a shared preset table, media preparation by a per-platform policy, round video messages, and capture output kept in the bytes cache.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_capture:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_capture
```

## Usage

```dart
import 'package:mpx_capture/mpx_capture.dart';

const transcoder = PlatformTranscoder();
final source = await transcoder.probe(pickedPath);
final offered = CompressionPreset.offeredFor(source.dimensions);

final job = transcoder.compress(
  TranscodeRequest(
    sourcePath: pickedPath,
    outputPath: '${tempDir.path}/send.mp4',
    preset: CompressionPreset.medium,
  ),
);
job.progress.listen((p) => print('${p.bytesWritten} B, ${p.fraction}'));
final output = await job.output; // or job.cancel()
```

### Media preparation

One call per picked item before upload, two at a time, off the UI isolate:

```dart
final preparer = MediaPreparer(
  codec: const PlatformPreparationCodec(),
  transcoder: const PlatformTranscoder(),
  outputDirectory: tempDir.path,
);
final policy = PreparationPolicy.forPlatform(defaultTargetPlatform);

final job = preparer.prepare(
  PreparationInput(path, mimeType: 'image/jpeg'),
  const PreparationIntent.photo(highQuality: false),
  policy,
);
job.progress.listen((fraction) => print(fraction));
final prepared = await job.result; // or job.cancel()
// prepared.path, .isOriginal, .dimensions, .thumbnail, .mimeType ...
```

A video goes `PreparationIntent.video(preset: ...)`, with the steps the
policy offers (`policy.offeredPresets(source)`) and its default
(`policy.defaultPreset(source, remembered: ...)`; the host remembers the
user's choice); `PreparationIntent.file()` keeps the bytes and makes a
thumbnail only.

| Policy | Still long side (HQ) | JPEG (HQ) | Thumbnail | Video |
| --- | --- | --- | --- | --- |
| `$Android` | 1280 (2560) | 80 (99) | 90 px at 55 | 432 / 640 / 848 / 1280 by the long side (> 1280: four, > 854: three, > 640: two, else one); default the remembered step, at most 848; 1000 MB or more not compressed |
| `$IOS` | 1280 (2560) | 60 (60) | 320 px at 40 | 480 to 1920 clamped to the source; default the remembered step, else 848 |
| `$Desktop` | 1280 (2560) | 87, progressive | 320 px at 87 | none |
| `$Web` | 2560 | 92, or 90 for PNG / BMP over 2 MB | poster 720 px at 90 | none |

`$Desktop` keeps an original JPEG of at most 4 bits per pixel that needs no
downscale. `$Web` keeps the original unless it is past 2560 px, a PNG or BMP
over 2 MB, or not a JPEG, PNG, BMP or GIF, and encodes again at 90 a result
over 6 MB. Animated stills always go as they are. Android writes baseline
JPEGs only. The web encoder is not there yet: the `$Web` policy's values are
ready for it.

### Round video

```dart
const recorder = PlatformRoundVideoRecorder();
if (!await recorder.requestPermission()) return;
final recording = await recorder.start(
  outputPath: '${tempDir.path}/round.mp4',
  config: const RoundVideoConfig(), // 384 px, ~1 Mbps, 30 fps, 64 kbps, 60 s
);
// In the tree: RoundVideoPreview(recording: recording)
await recording.pause();
await recording.resume();
await recording.switchCamera();
final output = await recording.stop(); // or recording.job.cancel()
```

The recording finishes by itself at `RoundVideoConfig.maxDuration`. Paused
time is cut out of the file. The front camera is mirrored in the preview and
in the file.

### Into the cache

The sender's own item plays at once from the store, before any upload:

```dart
final cache = CaptureCache(store: store); // the app's IBytesStore
final key = cache.mintKey();              // MediaKey.local(uuid), at start
final output = await job.output;
await cache.put(key, output);             // moves the file into the store

// After upload: the server key resolves to the same bytes, no copy.
await cache.alias(
  key,
  BytesCacheFetcher.cacheKeyOf(serverKey, FetchPart.content), // package:mpx
);
// Once the message is confirmed:
await cache.release(key);
```

The store keys the bytes by `CaptureCache.cacheKeyOf(key)`: the local key's
stable form, the same cache key the mpx fetch adapter uses for content; the
adapter's `cacheKeyOf` names the server key, so readers of the server key
find the aliased bytes. A store that keeps ranged resources takes the file in
one-megabyte pieces, as a complete ranged resource that a native player
streams from.

## Presets

| Preset | Max side | Video kbps | Audio kbps / channels |
| --- | --- | --- | --- |
| `tiny` | 432 | 750 | 32 / 1 |
| `veryLow` | 480 | 400 | 32 / 1 |
| `low` | 640 | 700 | 32 / 1 |
| `medium` | 848 | 1600 | 64 / 2 |
| `high` | 1280 | 3000 | 64 / 2 |
| `veryHigh` | 1920 | 6600 | 64 / 2 |

`tiny` is offered by the Android preparation policy only;
`CompressionPreset.shared` holds the other five.
H.264 High with a keyframe every second, AAC audio, MP4 out. The output
bitrate never exceeds the source's, and the frame is never scaled up. An
H.264 source that would not change is remuxed instead of re-encoded
(`CaptureOutput.reencoded` is false).

## Output and progress

- `CaptureProgress.bytesWritten` grows while the file is written;
  `fraction` is the encode position over the duration.
- The last report carries `finalSize` and `headerRewritten`: whether the
  head of the file changed after it was first written. The MP4 writers
  move the index to the front at the end, so an uploader that started on
  the growing file sends the head again.
- `CaptureJob.cancel()` stops the job and deletes the file; `output` then
  fails with `CaptureCancelled`. A source that is not a video fails with
  `CaptureFailed`.

## Platforms

| Platform | Compression | Round video |
| --- | --- | --- |
| Android (API 24+) | Media3 Transformer | CameraX preview through a GL stage into MediaCodec, MediaMuxer |
| iOS 15+, macOS 12+ | AVAssetReader into AVAssetWriter; an export session for a remux | AVCaptureSession into AVAssetWriter |

One compression runs at a time; jobs started together queue. On a Mac the
first camera counts as front, a second one as back.

## Permissions

Compression needs none. Round video needs the camera and the microphone;
`requestPermission()` asks for both, and `start` fails with
`CapturePermissionDenied` without them. The host declares them:

**Android**: the package's manifest declares `CAMERA` and `RECORD_AUDIO`
(and the camera as an optional feature); they merge into the app's
manifest, nothing to add. `requestPermission()` asks through the plugin's
activity.

**iOS and macOS** (`Info.plist`):

```xml
<key>NSCameraUsageDescription</key>
<string>Records round video messages.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Records the sound of round video messages.</string>
```

**macOS** sandbox entitlements (`DebugProfile.entitlements`,
`Release.entitlements`):

```xml
<key>com.apple.security.device.camera</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
```

## Testing

`package:mpx_capture/testing.dart` has `FakeTranscoder`,
`FakePreparationCodec`, `FakeRoundVideoRecorder` and their contract suites. The example app runs
them against the platform:

```shell
cd example
flutter test integration_test/transcoder_test.dart -d macos
flutter test integration_test/capture_cache_test.dart -d macos
flutter test integration_test/round_video_test.dart -d macos # asks for access
```

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [Capture (ADR 0007)](../../docs/adr/0007-capture.md)
- [Library, intake, preparation and picking (ADR 0011)](../../docs/adr/0011-library-and-picking.md)
- [Bytes cache, local keys and alias (ADR 0002)](../../docs/adr/0002-bytes-cache.md)
