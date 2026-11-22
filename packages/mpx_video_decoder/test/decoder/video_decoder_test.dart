import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';
import 'package:mpx_video_decoder/testing.dart';

import '../support/gated_video_engine.dart';

const _descriptor = MediaDescriptor(
  key: MediaKey.remote('fixture'),
  kind: MediaKind.video,
  animated: true,
);

ui.Image _image([int side = 4]) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint());
  final picture = recorder.endRecording();
  final image = picture.toImageSync(side, side);
  picture.dispose();
  return image;
}

DecodeRequest _request(
  Uint8List bytes, {
  FetchPart part = FetchPart.content,
  AssetSpec spec = const AssetSpec(pixelWidth: 64, pixelHeight: 64),
  FetchedContent? content,
}) => DecodeRequest(
  descriptor: _descriptor,
  spec: spec,
  part: part,
  content: content ?? FetchedContent.bytes(bytes),
);

VideoInfo _info(int width, int height) => VideoInfo(
  width: width,
  height: height,
  duration: const Duration(milliseconds: 100),
  frameRate: 30,
  hasAlpha: true,
);

/// Everything one decode reported, paintables and errors included.
final class _Report implements AssetProgress {
  @override
  void describe(MediaDescriptor descriptor) {}

  final List<
    ({AssetStage stage, AssetPaintable paintable, int bytes, AssetTier tier})
  >
  advances = [];
  final List<({Object error, AssetFailureKind kind})> failures = [];
  int cancels = 0;

  @override
  void advance(
    AssetStage stage,
    AssetPaintable paintable, {
    required int bytes,
    AssetTier tier = AssetTier.still,
  }) => advances.add((
    stage: stage,
    paintable: paintable,
    bytes: bytes,
    tier: tier,
  ));

  @override
  void fail(
    Object error, [
    StackTrace? stackTrace,
    AssetFailureKind kind = AssetFailureKind.transient,
  ]) => failures.add((error: error, kind: kind));

  @override
  void waiting() {}

  @override
  void transfer(int received, int? total) {}

  @override
  void awaitingUser() {}

  @override
  void bestReached() {}

  @override
  void cancelled() => cancels++;
}

void main() {
  final good = Uint8List.fromList([1, 2, 3]);
  final wide = Uint8List.fromList([4, 5, 6]);
  final refused = Uint8List.fromList([7]);
  final damaged = Uint8List.fromList([8]);
  final bad = Uint8List.fromList([9]);
  final huge = Uint8List.fromList([10]);

  late FakeVideoEngine fake;
  late GatedVideoEngine engine;
  late ManualPlaybackTickSource ticks;
  late PlaybackClock clock;
  late VideoFrameScheduler scheduler;
  late VideoDecoder decoder;
  late List<({Uint8List pixels, int width, int height})> uploaded;

  setUp(() {
    fake = FakeVideoEngine()
      ..accept(good, _info(64, 64), frameCount: 3)
      ..accept(wide, _info(32, 16), frameCount: 3)
      ..reject(refused, VideoRejection.unsupported)
      ..reject(huge, VideoRejection.limitExceeded)
      ..reject(damaged, VideoRejection.malformed);
    engine = GatedVideoEngine(fake);
    ticks = ManualPlaybackTickSource();
    clock = PlaybackClock(ticks: ticks);
    uploaded = [];
    scheduler = VideoFrameScheduler(
      engine: engine,
      atlas: VideoFrameAtlas.create(upload: (pixels, side) async => _image()),
      clock: clock,
      startTimer: ManualTimers().start,
    );
    decoder = VideoDecoder(
      engine: engine,
      scheduler: scheduler,
      decodeImage: (bytes) async => _image(),
      uploadPixels: (pixels, width, height) async {
        uploaded.add((pixels: pixels, width: width, height: height));
        return _image();
      },
    );
  });
  tearDown(() async {
    scheduler.dispose();
    clock.dispose();
    await fake.dispose();
  });

  group('over the fake engine', () {
    DecoderContract.run(
      () => DecoderHarness(
        decoder: decoder,
        valid: (part, spec) => _request(good, part: part, spec: spec),
        invalid: () => _request(bad),
      ),
    );
  });

  group('VideoDecoder', () {
    test('a full decode reports the still, then the animation', () async {
      final report = _Report();

      decoder.decode(_request(good), report);
      await pumpEventQueue();

      expect(report.advances.map((a) => a.stage), [
        AssetStage.firstFrame,
        AssetStage.full,
      ]);
      expect(report.advances.last.paintable.isAnimated, isTrue);
      expect(report.advances.last.tier, AssetTier.animated);
      expect(report.advances.first.paintable.isAnimated, isFalse);
      expect(report.failures, isEmpty);
    });

    test('the still is the clip first frame, as decoded', () async {
      decoder.decode(_request(good), _Report());
      await pumpEventQueue();

      final frame = uploaded.single;
      expect((frame.width, frame.height), (64, 64));
      expect(frame.pixels, hasLength(64 * 64 * 4));
      // The fake's frame 0: B 0, G 0, R 0, alpha 200, premultiplied BGRA.
      expect(frame.pixels.sublist(0, 4), [0, 0, 0, 200]);
    });

    test(
      'a first-frame-only decode ends with the still and frees the clip',
      () async {
        final report = _Report();

        decoder.decode(
          _request(
            good,
            spec: const AssetSpec(
              pixelWidth: 64,
              pixelHeight: 64,
              variant: AssetVariant.firstFrame,
            ),
          ),
          report,
        );
        await pumpEventQueue();

        expect(report.advances.map((a) => a.stage), [AssetStage.firstFrame]);
        expect(fake.openClips, 0);
      },
    );

    test('a thumbnail is an ordinary image: the placeholder', () async {
      final report = _Report();

      decoder.decode(_request(good, part: FetchPart.thumbnail), report);
      await pumpEventQueue();

      expect(report.advances.map((a) => a.stage), [AssetStage.placeholder]);
      expect(fake.openClips, 0);
    });

    testWidgets(
      'by default a thumbnail is decoded small, as a mini-thumbnail',
      (tester) async {
        final report = _Report();
        final plain = VideoDecoder(engine: engine, scheduler: scheduler);
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          ui.Canvas(recorder).drawRect(
            const ui.Rect.fromLTWH(0, 0, 100, 100),
            ui.Paint()..color = const ui.Color(0xFF336699),
          );
          final picture = recorder.endRecording();
          final source = await picture.toImage(200, 100);
          picture.dispose();
          final png = (await source.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          source.dispose();

          plain.decode(
            _request(png.buffer.asUint8List(), part: FetchPart.thumbnail),
            report,
          );
          while (report.advances.isEmpty && report.failures.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });

        expect(report.failures, isEmpty);
        // 40 x 20 pixels at 4 bytes each, not the 200 x 100 of the file.
        expect(report.advances.single.bytes, 40 * 20 * 4);
      },
    );

    test(
      'a rejected clip fails permanently with the reason and holds nothing',
      () async {
        final report = _Report();

        decoder.decode(_request(damaged), report);
        await pumpEventQueue();

        final failure = report.failures.single;
        expect(failure.kind, AssetFailureKind.permanent);
        expect(
          failure.error,
          isA<VideoDecodeRejected>().having(
            (e) => e.reason,
            'reason',
            VideoRejection.malformed,
          ),
        );
        expect(report.advances, isEmpty);
        expect(fake.openClips, 0);
      },
    );

    test('a clip this build cannot read fails as unsupported, so the pipeline '
        'tries the fallback', () async {
      final report = _Report();

      decoder.decode(_request(refused), report);
      await pumpEventQueue();

      final failure = report.failures.single;
      expect(failure.kind, AssetFailureKind.permanent);
      expect(
        failure.error,
        isA<DecodeFailure>().having(
          (e) => e.cause,
          'cause',
          isA<VideoDecodeRejected>().having(
            (e) => e.reason,
            'reason',
            VideoRejection.unsupported,
          ),
        ),
      );
      expect(report.advances, isEmpty);
      expect(fake.openClips, 0);
    });

    test('a clip past the size this build decodes fails as unsupported too: '
        'the platform may still draw it', () async {
      final report = _Report();

      decoder.decode(_request(huge), report);
      await pumpEventQueue();

      expect(
        report.failures.single.error,
        isA<DecodeFailure>().having(
          (e) => e.cause,
          'cause',
          isA<VideoDecodeRejected>().having(
            (e) => e.reason,
            'reason',
            VideoRejection.limitExceeded,
          ),
        ),
      );
      expect(fake.openClips, 0);
    });

    test(
      'decodes at the size class the spec snaps to, keeping the aspect',
      () async {
        decoder.decode(
          _request(
            wide,
            spec: const AssetSpec(pixelWidth: 100, pixelHeight: 100),
          ),
          _Report(),
        );
        await pumpEventQueue();

        // 100 px snaps up to the 128 class; 32x16 keeps its two to one.
        final frame = uploaded.single;
        expect((frame.width, frame.height), (128, 64));
        // The square probe was closed; the clip that plays is the fitted one.
        expect(fake.openClips, 1);
      },
    );

    test(
      'a spec above the largest class plays, decoded at the largest',
      () async {
        // The content preview on a phone is about 600 px: the
        // clip is decoded at 512 and drawn scaled up, and it plays.
        final report = _Report();
        decoder.decode(
          _request(
            good,
            spec: const AssetSpec(pixelWidth: 600, pixelHeight: 600),
          ),
          report,
        );
        await pumpEventQueue();

        expect((uploaded.single.width, uploaded.single.height), (512, 512));
        expect(report.advances.last.paintable.isAnimated, isTrue);
      },
    );

    test(
      'a file is opened by its path, never read into this isolate',
      () async {
        const path = '/media/clip.webm';
        fake.acceptSource(
          const VideoSource.file(path),
          _info(64, 64),
          frameCount: 3,
        );
        final report = _Report();

        decoder.decode(
          _request(good, content: const FetchedContent.file(path)),
          report,
        );
        await pumpEventQueue();

        expect(report.advances.map((a) => a.stage), [
          AssetStage.firstFrame,
          AssetStage.full,
        ]);
        expect(fake.opensOf(const VideoSource.file(path)), 1);
      },
    );

    test('a ranged resource is opened through its reader', () async {
      const source = VideoSource.ranged(readerApi: 0x1000, key: 'clip');
      fake.acceptSource(source, _info(64, 64), frameCount: 3);
      final report = _Report();

      decoder.decode(
        _request(
          good,
          content: const FetchedContent.ranged(readerApi: 0x1000, key: 'clip'),
        ),
        report,
      );
      await pumpEventQueue();

      expect(report.advances.map((a) => a.stage), [
        AssetStage.firstFrame,
        AssetStage.full,
      ]);
      expect(fake.opensOf(source), 1);
    });

    test('a ranged clip whose index has not landed opens when bytes land, '
        'and its playing clip wakes on each landing', () async {
      const source = VideoSource.ranged(readerApi: 0x1000, key: 'clip');
      fake.acceptSource(source, _info(64, 64), frameCount: 3);
      final landed = StreamController<void>.broadcast();
      addTearDown(landed.close);
      engine.stalledOpens = 2;
      final report = _Report();

      decoder.decode(
        _request(
          good,
          content: FetchedContent.ranged(
            readerApi: 0x1000,
            key: 'clip',
            landed: landed.stream,
          ),
        ),
        report,
      );
      await pumpEventQueue();
      expect(report.advances, isEmpty);
      expect(engine.opens, 1);

      landed.add(null);
      await pumpEventQueue();
      landed.add(null);
      await pumpEventQueue();

      expect(engine.opens, 3);
      expect(report.advances.map((a) => a.stage), [
        AssetStage.firstFrame,
        AssetStage.full,
      ]);
      expect(report.failures, isEmpty);
    });

    test('a clip read in place costs its frame, not its file', () async {
      const path = '/media/clip.webm';
      fake.acceptSource(
        const VideoSource.file(path),
        _info(64, 64),
        frameCount: 3,
      );
      final report = _Report();

      decoder.decode(
        _request(good, content: const FetchedContent.file(path)),
        report,
      );
      await pumpEventQueue();

      expect(report.advances.last.bytes, 64 * 64 * 4);
    });

    test(
      'a cancel while the first frame decodes reports nothing and frees the clip',
      () async {
        final report = _Report();
        engine.hold();

        final task = decoder.decode(_request(good), report);
        await pumpEventQueue();
        task.cancel();
        engine.release();
        await pumpEventQueue();

        expect(report.advances, isEmpty);
        expect(report.failures, isEmpty);
        expect(fake.openClips, 0);
      },
    );

    test('disposing the animation closes its clip', () async {
      final report = _Report();
      decoder.decode(_request(good), report);
      await pumpEventQueue();
      expect(fake.openClips, 1);

      report.advances.last.paintable.dispose();
      await pumpEventQueue();

      expect(fake.openClips, 0);
    });

    test(
      'with logFailures on, each stage is logged and a failure says why',
      () async {
        final lines = <String?>[];
        final previous = debugPrint;
        debugPrint = (message, {wrapWidth}) => lines.add(message);
        VideoDecoder.logFailures = true;
        addTearDown(() {
          debugPrint = previous;
          VideoDecoder.logFailures = false;
        });

        decoder.decode(_request(refused), _Report());
        decoder.decode(_request(good), _Report());
        await pumpEventQueue();

        // Every stage of the clip that plays, and why the other one stopped.
        expect(lines, everyElement(startsWith('mpx_video: ')));
        expect(
          lines.where((l) => l!.contains('did not decode')).single,
          contains('unsupported'),
        );
        for (final stage in ['decode', 'opened', 'first frame', 'still']) {
          expect(lines.where((l) => l!.contains(' $stage')), isNotEmpty);
        }
      },
    );

    test('by default a failure stays silent', () async {
      final lines = <String?>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add(message);
      addTearDown(() => debugPrint = previous);

      decoder.decode(_request(refused), _Report());
      await pumpEventQueue();

      expect(lines, isEmpty);
    });

    group('gives its content back', () {
      late int released;
      FetchedContent held(String path) =>
          FetchedContent.file(path, onRelease: () => released++);

      setUp(() {
        released = 0;
        fake.acceptSource(
          const VideoSource.file('/media/a.webm'),
          _info(64, 64),
          frameCount: 3,
        );
      });

      test('when its animation is disposed, not before', () async {
        final report = _Report();
        decoder.decode(_request(good, content: held('/media/a.webm')), report);
        await pumpEventQueue();
        expect(released, 0);

        report.advances.last.paintable.dispose();
        await pumpEventQueue();

        expect(released, 1);
      });

      test('once a first-frame-only decode ends', () async {
        decoder.decode(
          _request(
            good,
            content: held('/media/a.webm'),
            spec: const AssetSpec(
              pixelWidth: 64,
              pixelHeight: 64,
              variant: AssetVariant.firstFrame,
            ),
          ),
          _Report(),
        );
        await pumpEventQueue();

        expect(released, 1);
      });

      test('when the clip is refused', () async {
        decoder.decode(
          _request(good, content: held('/media/b.webm')),
          _Report(),
        );
        await pumpEventQueue();

        expect(released, 1);
      });

      test('when the decode is cancelled', () async {
        engine.hold();
        final task = decoder.decode(
          _request(good, content: held('/media/a.webm')),
          _Report(),
        );
        await pumpEventQueue();
        task.cancel();
        engine.release();
        await pumpEventQueue();

        expect(released, 1);
      });

      test('after reading a thumbnail', () async {
        final dir = Directory.systemTemp.createTempSync('video_thumbnail_');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/thumb.png')..writeAsBytesSync(good);
        final report = _Report();

        decoder.decode(
          _request(good, part: FetchPart.thumbnail, content: held(file.path)),
          report,
        );
        while (report.advances.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        expect(released, 1);
      });
    });

    test('reports the still and the encoded size as the cost', () async {
      final report = _Report();

      decoder.decode(_request(good), report);
      await pumpEventQueue();

      expect(report.advances.first.bytes, 64 * 64 * 4);
      expect(report.advances.last.bytes, 64 * 64 * 4 + good.length);
    });
  });
}
