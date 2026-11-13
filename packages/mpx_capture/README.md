# mpx_capture

Optional media capture for mpx: compression before send against a shared preset table, round video messages, and capture output kept in the bytes cache.

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
| `veryLow` | 480 | 400 | 32 / 1 |
| `low` | 640 | 700 | 32 / 1 |
| `medium` | 848 | 1600 | 64 / 2 |
| `high` | 1280 | 3000 | 64 / 2 |
| `veryHigh` | 1920 | 6600 | 64 / 2 |

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
`FakeRoundVideoRecorder` and their contract suites. The example app runs
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
- [Bytes cache, local keys and alias (ADR 0002)](../../docs/adr/0002-bytes-cache.md)
