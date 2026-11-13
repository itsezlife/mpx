# mpx_capture

Optional media capture for mpx: compression before send against a shared preset table.

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

| Platform | Compression |
| --- | --- |
| Android (API 24+) | Media3 Transformer |
| iOS 15+, macOS 12+ | AVAssetReader into AVAssetWriter; an export session for a remux |

One compression runs at a time; jobs started together queue.

## Testing

`package:mpx_capture/testing.dart` has `FakeTranscoder` and
`TranscoderContract`. The example app runs the contract against the
platform transcoder:

```shell
cd example && flutter test integration_test/transcoder_test.dart -d macos
```

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [Capture (ADR 0007)](../../docs/adr/0007-capture.md)
