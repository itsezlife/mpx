import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_core/mpx_core.dart';

SourceVideo _source(
  int width,
  int height, {
  int? videoBitrate = 10000000,
  SourceCodec codec = SourceCodec.h264,
}) => SourceVideo(
  dimensions: MediaDimensions(width, height),
  duration: const Duration(seconds: 10),
  videoBitrate: videoBitrate,
  codec: codec,
);

void main() {
  group('CompressionPreset table', () {
    test('holds the shared size / kbps values', () {
      final table = {
        for (final p in CompressionPreset.values)
          p: (p.maxSide, p.videoKbps, p.audioKbps, p.audioChannels),
      };
      expect(table, {
        CompressionPreset.veryLow: (480, 400, 32, 1),
        CompressionPreset.low: (640, 700, 32, 1),
        CompressionPreset.medium: (848, 1600, 64, 2),
        CompressionPreset.high: (1280, 3000, 64, 2),
        CompressionPreset.veryHigh: (1920, 6600, 64, 2),
      });
    });

    test('bitrates are in bits per second', () {
      expect(CompressionPreset.medium.videoBitrate, 1600000);
      expect(CompressionPreset.medium.audioBitrate, 64000);
    });
  });

  group('CompressionPreset.planFor', () {
    test('scales the long side down to the preset, keeping aspect', () {
      final plan = CompressionPreset.high.planFor(_source(1920, 1080));
      expect(plan.size, const MediaDimensions(1280, 720));
    });

    test('scales a portrait source by its long side', () {
      final plan = CompressionPreset.veryLow.planFor(_source(1080, 1920));
      expect(plan.size, const MediaDimensions(270, 480));
    });

    test('never scales up', () {
      final plan = CompressionPreset.veryHigh.planFor(_source(640, 360));
      expect(plan.size, const MediaDimensions(640, 360));
    });

    test('rounds both sides to even pixels', () {
      // 1000 x 563 to 480: 480 x 270.24.
      expect(
        CompressionPreset.veryLow.planFor(_source(1000, 563)).size,
        const MediaDimensions(480, 270),
      );
      // An odd source that is not scaled still gets even sides.
      expect(
        CompressionPreset.veryHigh.planFor(_source(641, 361)).size,
        const MediaDimensions(640, 360),
      );
    });

    test('the video bitrate never exceeds the source bitrate', () {
      expect(
        CompressionPreset.veryHigh
            .planFor(_source(1920, 1080, videoBitrate: 2000000))
            .videoBitrate,
        2000000,
      );
      expect(
        CompressionPreset.low
            .planFor(_source(1920, 1080, videoBitrate: 2000000))
            .videoBitrate,
        700000,
      );
    });

    test('an unknown source bitrate takes the preset bitrate', () {
      final plan = CompressionPreset.medium.planFor(
        _source(1920, 1080, videoBitrate: null),
      );
      expect(plan.videoBitrate, 1600000);
    });

    test('carries the preset audio settings', () {
      final plan = CompressionPreset.veryLow.planFor(_source(1920, 1080));
      expect((plan.audioBitrate, plan.audioChannels), (32000, 1));
    });

    test('passes an H.264 source through when nothing would change', () {
      final plan = CompressionPreset.high.planFor(
        _source(1280, 720, videoBitrate: 2500000),
      );
      expect(plan.passthrough, isTrue);
    });

    test('re-encodes when the size, the bitrate or the codec changes', () {
      expect(
        CompressionPreset.medium
            .planFor(_source(1280, 720, videoBitrate: 1000000))
            .passthrough,
        isFalse,
        reason: 'size changes',
      );
      expect(
        CompressionPreset.high
            .planFor(_source(1280, 720, videoBitrate: 5000000))
            .passthrough,
        isFalse,
        reason: 'bitrate changes',
      );
      expect(
        CompressionPreset.high
            .planFor(
              _source(
                1280,
                720,
                videoBitrate: 1000000,
                codec: SourceCodec.hevc,
              ),
            )
            .passthrough,
        isFalse,
        reason: 'codec changes',
      );
      expect(
        CompressionPreset.high
            .planFor(_source(1280, 720, videoBitrate: null))
            .passthrough,
        isFalse,
        reason: 'bitrate unknown',
      );
    });
  });

  group('CompressionPreset.offeredFor', () {
    test('offers the steps below the source and the first that holds it', () {
      expect(CompressionPreset.offeredFor(const MediaDimensions(1280, 720)), [
        CompressionPreset.veryLow,
        CompressionPreset.low,
        CompressionPreset.medium,
        CompressionPreset.high,
      ]);
      expect(
        CompressionPreset.offeredFor(const MediaDimensions(720, 1280)),
        hasLength(4),
      );
    });

    test('a small source gets the lowest step only', () {
      expect(CompressionPreset.offeredFor(const MediaDimensions(320, 240)), [
        CompressionPreset.veryLow,
      ]);
    });

    test('a source above every step gets all of them', () {
      expect(
        CompressionPreset.offeredFor(const MediaDimensions(3840, 2160)),
        CompressionPreset.values,
      );
    });
  });
}
