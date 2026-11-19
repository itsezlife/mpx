import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_core/mpx_core.dart';

const _mb = 1024 * 1024;

StillSource _still(
  int width,
  int height, {
  String mime = 'image/jpeg',
  int bytes = 1000000,
  bool animated = false,
}) => StillSource(
  dimensions: MediaDimensions(width, height),
  mimeType: mime,
  byteSize: bytes,
  animated: animated,
);

SourceVideo _video(int width, int height) => SourceVideo(
  dimensions: MediaDimensions(width, height),
  duration: const Duration(seconds: 10),
  codec: SourceCodec.h264,
  videoBitrate: 8000000,
);

StillPlan$Encode _encode(StillPlan plan) => plan as StillPlan$Encode;

void main() {
  group('forPlatform', () {
    test('picks the policy of each platform', () {
      expect(
        PreparationPolicy.forPlatform(TargetPlatform.android),
        PreparationPolicy.$Android,
      );
      expect(
        PreparationPolicy.forPlatform(TargetPlatform.iOS),
        PreparationPolicy.$IOS,
      );
      for (final desktop in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          PreparationPolicy.forPlatform(desktop),
          PreparationPolicy.$Desktop,
        );
      }
      expect(
        PreparationPolicy.forPlatform(TargetPlatform.android, web: true),
        PreparationPolicy.$Web,
      );
    });
  });

  group(r'$Android stills', () {
    const policy = PreparationPolicy.$Android;

    test('1280 px at JPEG 80, 2560 px at 99 in high quality', () {
      final standard = _encode(policy.planStill(_still(4032, 3024)));
      expect(standard.size, const MediaDimensions(1280, 960));
      expect(standard.quality, 80);
      expect(standard.progressive, isFalse);
      final hq = _encode(
        policy.planStill(_still(4032, 3024), highQuality: true),
      );
      expect(hq.size, const MediaDimensions(2560, 1920));
      expect(hq.quality, 99);
    });

    test('a small source is encoded at its own size, never scaled up', () {
      final plan = _encode(policy.planStill(_still(800, 600)));
      expect(plan.size, const MediaDimensions(800, 600));
    });

    test('thumbnails are 90 px at 55', () {
      expect(policy.thumbnail, const ThumbnailSpec(side: 90, quality: 55));
    });
  });

  group(r'$IOS stills', () {
    const policy = PreparationPolicy.$IOS;

    test('JPEG 60 at both sizes; high quality changes the size only', () {
      final standard = _encode(policy.planStill(_still(3024, 4032)));
      expect(standard.size, const MediaDimensions(960, 1280));
      expect(standard.quality, 60);
      final hq = _encode(
        policy.planStill(_still(3024, 4032), highQuality: true),
      );
      expect(hq.size, const MediaDimensions(1920, 2560));
      expect(hq.quality, 60);
    });

    test('thumbnails are 320 px at 40', () {
      expect(policy.thumbnail, const ThumbnailSpec(side: 320, quality: 40));
    });
  });

  group(r'$Desktop stills', () {
    const policy = PreparationPolicy.$Desktop;

    test('progressive JPEG 87 at 1280, 2560 in high quality', () {
      final plan = _encode(policy.planStill(_still(4000, 3000)));
      expect(plan.size, const MediaDimensions(1280, 960));
      expect(plan.quality, 87);
      expect(plan.progressive, isTrue);
      expect(
        _encode(policy.planStill(_still(4000, 3000), highQuality: true)).size,
        const MediaDimensions(2560, 1920),
      );
    });

    test('keeps a light JPEG that needs no downscale', () {
      // 1200 x 900 at 4 bits per pixel is 540000 bytes.
      expect(
        policy.planStill(_still(1200, 900, bytes: 540000)),
        const StillPlan.keep(),
      );
      expect(
        policy.planStill(_still(1200, 900, bytes: 540001)),
        isA<StillPlan$Encode>(),
        reason: 'over 4 bits per pixel',
      );
      expect(
        policy.planStill(_still(2000, 1500, bytes: 100000)),
        isA<StillPlan$Encode>(),
        reason: 'needs a downscale',
      );
      expect(
        policy.planStill(_still(1200, 900, bytes: 1000, mime: 'image/png')),
        isA<StillPlan$Encode>(),
        reason: 'not a JPEG',
      );
      expect(
        policy.planStill(_still(2000, 1500, bytes: 1000000), highQuality: true),
        const StillPlan.keep(),
        reason: 'fits 2560 in high quality',
      );
    });

    test('thumbnails are 320 px at 87', () {
      expect(policy.thumbnail, const ThumbnailSpec(side: 320, quality: 87));
    });
  });

  group(r'$Web stills', () {
    const policy = PreparationPolicy.$Web;

    test('leaves a small PNG, a JPEG and a GIF alone', () {
      expect(
        policy.planStill(_still(1000, 800, mime: 'image/png', bytes: _mb)),
        const StillPlan.keep(),
      );
      expect(policy.planStill(_still(2560, 1440)), const StillPlan.keep());
      expect(
        policy.planStill(
          _still(5000, 4000, mime: 'image/gif', bytes: 20 * _mb),
        ),
        const StillPlan.keep(),
        reason: 'a GIF is never re-encoded',
      );
    });

    test('re-encodes past 2560 px at the default quality', () {
      final plan = _encode(policy.planStill(_still(5120, 2880)));
      expect(plan.size, const MediaDimensions(2560, 1440));
      expect(plan.quality, 92);
    });

    test('re-encodes a PNG or BMP over 2 MB at 90', () {
      for (final mime in ['image/png', 'image/bmp']) {
        final plan = _encode(
          policy.planStill(_still(1000, 800, mime: mime, bytes: 2 * _mb + 1)),
        );
        expect(plan.quality, 90);
        expect(plan.size, const MediaDimensions(1000, 800));
      }
    });

    test('re-encodes a format the server does not take', () {
      expect(
        policy.planStill(_still(1000, 800, mime: 'image/webp', bytes: 1000)),
        isA<StillPlan$Encode>(),
      );
      expect(
        policy.planStill(_still(1000, 800, mime: 'image/heic', bytes: 1000)),
        isA<StillPlan$Encode>(),
      );
    });

    test('a result over 6 MB is encoded again at 90', () {
      final first = _encode(policy.planStill(_still(5120, 2880)));
      expect(policy.retryStill(first, resultBytes: 6 * _mb), isNull);
      final again = policy.retryStill(first, resultBytes: 6 * _mb + 1);
      expect(again?.quality, 90);
      expect(again?.size, first.size);
      expect(
        PreparationPolicy.$Android.retryStill(first, resultBytes: 50 * _mb),
        isNull,
        reason: 'only the web policy retries',
      );
    });

    test('the video poster is 720 px at 90', () {
      expect(policy.thumbnail, const ThumbnailSpec(side: 720, quality: 90));
    });
  });

  group('every policy', () {
    test('runs two items at a time', () {
      for (final policy in [
        PreparationPolicy.$Android,
        PreparationPolicy.$IOS,
        PreparationPolicy.$Desktop,
        PreparationPolicy.$Web,
      ]) {
        expect(policy.concurrency, 2);
      }
    });

    test('keeps an animated still as it is', () {
      for (final policy in [
        PreparationPolicy.$Android,
        PreparationPolicy.$IOS,
        PreparationPolicy.$Desktop,
      ]) {
        expect(
          policy.planStill(
            _still(4000, 3000, mime: 'image/gif', animated: true),
          ),
          const StillPlan.keep(),
        );
      }
    });
  });

  group(r'$Android video', () {
    const policy = PreparationPolicy.$Android;

    test('offers 432, 640, 848, 1280 by the long side', () {
      List<int> offered(int w, int h) => [
        for (final p in policy.offeredPresets(_video(w, h))) p.maxSide,
      ];
      expect(offered(1920, 1080), [432, 640, 848, 1280]);
      expect(offered(1281, 720), [432, 640, 848, 1280]);
      expect(offered(1280, 720), [432, 640, 848]);
      expect(offered(855, 480), [432, 640, 848]);
      expect(offered(854, 480), [432, 640]);
      expect(offered(480, 641), [432, 640]);
      expect(offered(640, 360), [432]);
      expect(offered(320, 240), [432]);
    });

    test('defaults to the remembered choice, at most 848', () {
      final fullHd = _video(1920, 1080);
      expect(policy.defaultPreset(fullHd), CompressionPreset.medium);
      expect(
        policy.defaultPreset(fullHd, remembered: CompressionPreset.high),
        CompressionPreset.medium,
      );
      expect(
        policy.defaultPreset(fullHd, remembered: CompressionPreset.tiny),
        CompressionPreset.tiny,
      );
      expect(
        policy.defaultPreset(
          _video(854, 480),
          remembered: CompressionPreset.medium,
        ),
        CompressionPreset.low,
        reason: 'clamped to the top offered step',
      );
      expect(policy.defaultPreset(_video(320, 240)), CompressionPreset.tiny);
    });

    test('a file of 1000 MB or more is not compressed', () {
      final source = _video(1920, 1080);
      expect(policy.offeredPresets(source, byteSize: 1000 * _mb), isEmpty);
      expect(policy.defaultPreset(source, byteSize: 1000 * _mb), isNull);
      expect(
        policy.offeredPresets(source, byteSize: 1000 * _mb - 1),
        hasLength(4),
      );
    });
  });

  group(r'$IOS video', () {
    const policy = PreparationPolicy.$IOS;

    test('offers 480 to 1920 clamped to the source', () {
      expect(policy.offeredPresets(_video(1920, 1080)), [
        CompressionPreset.veryLow,
        CompressionPreset.low,
        CompressionPreset.medium,
        CompressionPreset.high,
        CompressionPreset.veryHigh,
      ]);
      expect(policy.offeredPresets(_video(1280, 720)), [
        CompressionPreset.veryLow,
        CompressionPreset.low,
        CompressionPreset.medium,
        CompressionPreset.high,
      ]);
      expect(policy.offeredPresets(_video(480, 360)), [
        CompressionPreset.veryLow,
      ]);
    });

    test('defaults to the remembered preset, else Medium, clamped', () {
      expect(
        policy.defaultPreset(_video(1920, 1080)),
        CompressionPreset.medium,
      );
      expect(
        policy.defaultPreset(
          _video(1920, 1080),
          remembered: CompressionPreset.veryHigh,
        ),
        CompressionPreset.veryHigh,
      );
      expect(
        policy.defaultPreset(_video(640, 360)),
        CompressionPreset.low,
        reason: 'Medium clamped to the source',
      );
    });
  });

  group('desktop and web video', () {
    test('offer nothing and do not transcode', () {
      for (final policy in [
        PreparationPolicy.$Desktop,
        PreparationPolicy.$Web,
      ]) {
        expect(policy.offeredPresets(_video(1920, 1080)), isEmpty);
        expect(policy.defaultPreset(_video(1920, 1080)), isNull);
      }
    });
  });
}
