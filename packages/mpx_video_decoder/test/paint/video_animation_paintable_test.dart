import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';
import 'package:mpx_video_decoder/testing.dart';

const _info = VideoInfo(
  width: 16,
  height: 16,
  duration: Duration(milliseconds: 100),
  frameRate: 30,
  hasAlpha: true,
);

ui.Image _solid(int rgba, {int side = 16}) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    ui.Paint()..color = ui.Color(rgba),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(side, side);
  picture.dispose();
  return image;
}

/// Keeps what is drawn, as the arguments of each `drawImageRect`.
final class _RecordingCanvas implements ui.Canvas {
  final List<({ui.Image image, Rect src, Rect dst, double alpha})> draws = [];

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, ui.Paint paint) =>
      draws.add((image: image, src: src, dst: dst, alpha: paint.color.a));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  final bytes = Uint8List.fromList([1, 2, 3]);
  late FakeVideoEngine engine;
  late ManualPlaybackTickSource ticks;
  late PlaybackClock clock;
  late ManualTimers timers;
  late VideoFrameScheduler scheduler;
  late VideoClip clip;
  var now = Duration.zero;
  var disposed = 0;

  Future<void> tick() async {
    now += const Duration(milliseconds: 16);
    ticks.tick(now);
    await pumpEventQueue();
  }

  VideoFrameScheduler build({int budget = 32 * 1024 * 1024}) =>
      VideoFrameScheduler(
        engine: engine,
        atlas: VideoFrameAtlas.create(
          budgetBytes: budget,
          upload: (pixels, side) async => _solid(0xFF000000, side: 4),
        ),
        clock: clock,
        startTimer: timers.start,
      );

  VideoAnimationPaintable paintable({Object key = 'a'}) =>
      VideoAnimationPaintable(
        key: key,
        clip: clip,
        firstFrame: _solid(0xFF00FF00),
        scheduler: scheduler,
        onDispose: () => disposed++,
      );

  /// Paints at [ms] of the shared clock, as a surface would each frame.
  Future<_RecordingCanvas> paintAt(
    VideoAnimationPaintable p,
    int ms, {
    bool loop = true,
    AssetRestFrame rest = AssetRestFrame.first,
  }) async {
    final canvas = _RecordingCanvas();
    p.paint(
      canvas,
      const Rect.fromLTWH(0, 0, 16, 16),
      AssetPaintContext(
        time: Duration(milliseconds: ms),
        loop: loop,
        restFrame: rest,
      ),
    );
    await tick();
    return canvas;
  }

  setUp(() async {
    now = Duration.zero;
    disposed = 0;
    engine = FakeVideoEngine()..accept(bytes, _info, frameCount: 3);
    ticks = ManualPlaybackTickSource();
    clock = PlaybackClock(ticks: ticks);
    timers = ManualTimers();
    scheduler = build();
    clip =
        ((await engine.open(VideoSource.bytes(bytes), width: 16, height: 16))
                as VideoClipOpened)
            .clip;
  });
  tearDown(() {
    scheduler.dispose();
    clock.dispose();
  });

  group('VideoAnimationPaintable at half frame rate', () {
    // 60 fps, 8 frames; the fake's blue is 16 times the frame index.
    final bytes60 = Uint8List.fromList([6, 0]);
    const info60 = VideoInfo(
      width: 16,
      height: 16,
      duration: Duration(milliseconds: 133),
      frameRate: 60,
      hasAlpha: true,
    );
    late FrameTexturePool pool;
    late _IndexRecordingWriter writer;

    setUp(() async {
      scheduler.dispose();
      pool = FrameTexturePool(
        host: FakeFrameTextureHost(),
        sizeClasses: const [64],
      );
      await pool.warm(64, 1);
      writer = _IndexRecordingWriter();
      scheduler = VideoFrameScheduler(
        engine: engine,
        atlas: VideoFrameAtlas.create(
          upload: (pixels, side) async => _solid(0xFF000000, side: 4),
          sizeClasses: const [64],
        ),
        clock: clock,
        textures: pool,
        textureWriter: writer,
        startTimer: timers.start,
      );
      engine.accept(bytes60, info60, frameCount: 8);
      clip =
          ((await engine.open(
                    VideoSource.bytes(bytes60),
                    width: 16,
                    height: 16,
                  ))
                  as VideoClipOpened)
              .clip;
    });
    tearDown(() => pool.dispose());

    Future<List<int>> posted({required bool halfFrameRate}) async {
      final p = paintable();
      for (var ms = 0; ms <= 260; ms += 16) {
        final context = AssetPaintContext(
          time: Duration(milliseconds: ms),
          halfFrameRate: halfFrameRate,
        );
        p
          ..advancePlayback(context)
          ..paint(
            _RecordingCanvas(),
            const Rect.fromLTWH(0, 0, 16, 16),
            context,
          );
        await tick();
      }
      p.dispose();
      return writer.indices;
    }

    test('posts only every second frame of a 60 fps clip', () async {
      final indices = await posted(halfFrameRate: true);

      expect(indices, isNotEmpty);
      expect(indices.where((index) => index.isOdd), isEmpty);
    });

    test('at full rate it posts the odd frames too', () async {
      final indices = await posted(halfFrameRate: false);

      expect(indices.where((index) => index.isOdd), isNotEmpty);
    });
  });

  // A clip that comes back keeps its decoder's position and its
  // frame, so it shows the frame it left on and goes on from there,
  // with the frames it had decoded ahead, so the next frame shows at
  // its time, with no hold and no skip.
  group('VideoAnimationPaintable that leaves the screen and comes back', () {
    // 30 fps, 12 frames: the fake's blue is 16 times the frame index.
    final bytes12 = Uint8List.fromList([12, 0]);
    const info12 = VideoInfo(
      width: 16,
      height: 16,
      duration: Duration(milliseconds: 400),
      frameRate: 30,
      hasAlpha: true,
    );
    late FrameTexturePool pool;
    late _IndexRecordingWriter writer;

    VideoFrameScheduler withTextures({
      int keptAheadBytes = VideoFrameScheduler.defaultKeptAheadBytes,
    }) => VideoFrameScheduler(
      engine: engine,
      atlas: VideoFrameAtlas.create(
        upload: (pixels, side) async => _solid(0xFF000000, side: 4),
        sizeClasses: const [64],
      ),
      clock: clock,
      textures: pool,
      textureWriter: writer,
      startTimer: timers.start,
      keptAheadBytes: keptAheadBytes,
    );

    setUp(() async {
      scheduler.dispose();
      pool = FrameTexturePool(
        host: FakeFrameTextureHost(),
        sizeClasses: const [64],
      );
      await pool.warm(64, 2);
      writer = _IndexRecordingWriter();
      scheduler = withTextures();
      engine.accept(bytes12, info12, frameCount: 12);
      clip =
          ((await engine.open(
                    VideoSource.bytes(bytes12),
                    width: 16,
                    height: 16,
                  ))
                  as VideoClipOpened)
              .clip;
    });
    tearDown(() => pool.dispose());

    Future<void> play(VideoAnimationPaintable p, int from, int to) async {
      for (var ms = from; ms < to; ms += 16) {
        p.advancePlayback(AssetPaintContext(time: Duration(milliseconds: ms)));
        await tick();
      }
    }

    // Plays [p] to 200 ms, leaves the screen and comes back [away] ms later
    // (telling it playback resumed unless [resumed] is false), plays 150 ms
    // more; returns the frame it left on and the frames posted after.
    // [keepsFrame] says the texture it left on shows again at once.
    Future<({int left, List<int> after})> leaveAndComeBack(
      VideoAnimationPaintable p, {
      int away = 1800,
      bool resumed = true,
      bool keepsFrame = true,
    }) async {
      await play(p, 0, 200);
      final texture = p.texture;
      expect(texture, isNotNull);
      final left = writer.indices.last;
      expect(left, greaterThan(2));

      p.leftScreen();
      timers.elapse(Duration.zero);
      expect(scheduler.leaseCount, 0, reason: 'it left: its lease went');
      for (var i = 0; i < away ~/ 16; i++) {
        await tick();
      }

      final posted = writer.indices.length;
      final back = 200 + away;
      if (resumed) p.playbackResumed();
      p.advancePlayback(AssetPaintContext(time: Duration(milliseconds: back)));
      if (keepsFrame) {
        expect(p.texture, texture, reason: 'its last frame at once');
      } else {
        expect(p.texture, isNull, reason: 'its still, its first frame');
      }
      await play(p, back + 16, back + 150);
      return (left: left, after: writer.indices.skip(posted).toList());
    }

    group('position and seek', () {
      test('it says how far into its pass its clip is', () async {
        final p = paintable();
        addTearDown(p.dispose);
        expect(p.playbackPosition, Duration.zero);

        await play(p, 0, 200);

        expect(p.playbackPosition, const Duration(milliseconds: 192));
      });

      // Frame i of the 30 fps clip lies at i * 33 ms: 320 ms is frame 10's
      // time rounded up from 9's, so the first frame at or after it is 10.
      test('a seek forward goes to the frame there and plays on from it, '
          'none skipped, none twice', () async {
        final p = paintable();
        addTearDown(p.dispose);
        await play(p, 0, 100);
        final posted = writer.indices.length;

        p.seekPlayback(const Duration(milliseconds: 320));
        await play(p, 100, 200);

        final after = writer.indices.skip(posted).toList();
        expect(after.first, 10);
        // One frame after another, round the 12 of a pass.
        for (var i = 1; i < after.length; i++) {
          expect((after[i] - after[i - 1]) % 12, inInclusiveRange(0, 1));
        }
        expect(after.toSet().length, greaterThan(1));
        expect(engine.seeks, [const Duration(milliseconds: 320)]);
      });

      test(
        'a seek back goes back, through the engine, not round a pass',
        () async {
          final p = paintable();
          addTearDown(p.dispose);
          await play(p, 0, 250);
          final posted = writer.indices.length;

          p.seekPlayback(const Duration(milliseconds: 120));
          await play(p, 250, 300);

          expect(writer.indices.skip(posted).first, 4);
          expect(
            p.playbackPosition,
            greaterThanOrEqualTo(const Duration(milliseconds: 120)),
          );
          expect(
            p.playbackPosition,
            lessThan(const Duration(milliseconds: 250)),
          );
        },
      );

      test('a seek while it has no lease applies to the next one', () async {
        final p = paintable();
        addTearDown(p.dispose);
        await play(p, 0, 100);
        p.leftScreen();
        timers.elapse(Duration.zero);
        expect(scheduler.leaseCount, 0);

        p
          ..seekPlayback(const Duration(milliseconds: 320))
          ..playbackResumed();
        final posted = writer.indices.length;
        await play(p, 500, 550);

        expect(writer.indices.skip(posted).first, 10);
      });

      test('the picture handed with a seek shows until the frame there is '
          'drawn, then goes', () async {
        final p = paintable();
        addTearDown(p.dispose);
        await play(p, 0, 100);
        final picture = _solid(0xFFFF0000, side: 8);
        final mine = picture.clone();
        addTearDown(mine.dispose);

        p.seekPlayback(const Duration(milliseconds: 320), picture: picture);

        expect(p.texture, isNull);
        final canvas = _RecordingCanvas();
        p.paint(
          canvas,
          const Rect.fromLTWH(0, 0, 16, 16),
          const AssetPaintContext(time: Duration(milliseconds: 100)),
        );
        expect(canvas.draws.single.image.isCloneOf(mine), isTrue);

        await play(p, 116, 250);

        expect(picture.debugDisposed, isTrue);
        final after = _RecordingCanvas();
        p.paint(
          after,
          const Rect.fromLTWH(0, 0, 16, 16),
          const AssetPaintContext(time: Duration(milliseconds: 250)),
        );
        expect(after.draws.single.image.isCloneOf(mine), isFalse);
      });
    });

    test('shows the frame it left on at once and plays on from the next '
        'one, frame by frame', () async {
      final p = paintable();
      addTearDown(p.dispose);
      final (:left, :after) = await leaveAndComeBack(p);

      // 150 ms at 30 fps: each frame the one after the last.
      expect(after, [for (var i = 1; i <= 5; i++) left + i]);
    });

    test('a stop shorter than the resume gap is not played either', () async {
      final p = paintable();
      addTearDown(p.dispose);
      // No resume said: the paintable counts the 300 ms as played, the
      // clip that comes back does not.
      final (:left, :after) = await leaveAndComeBack(
        p,
        away: 300,
        resumed: false,
      );

      expect(after.first, left + 1);
    });

    // Without them the decoder is past the frames after the one
    // it left on, so going on from it would hold it for their time and then
    // skip them. It starts over instead, from its still.
    test('with no budget for frames decoded ahead it starts over from its '
        'first frame, frame by frame', () async {
      scheduler.dispose();
      scheduler = withTextures(keptAheadBytes: 0);
      final p = paintable();
      addTearDown(p.dispose);
      final (left: _, :after) = await leaveAndComeBack(p, keepsFrame: false);

      expect(after, isNotEmpty, reason: 'it plays again');
      // Its first frame until the texture shows it, then one after another.
      expect(after.first, 0);
      for (var i = 1; i < after.length; i++) {
        expect(after[i] - after[i - 1], inInclusiveRange(0, 1));
      }
      expect(after.last, greaterThan(0));
    });

    test('the clip away longest gives up its frames first', () async {
      scheduler.dispose();
      // 16 x 16 frames of 1 KiB: one clip's ring and decode, not two.
      scheduler = withTextures(keptAheadBytes: 5 * 1024);
      final other =
          ((await engine.open(
                    VideoSource.bytes(bytes12),
                    width: 16,
                    height: 16,
                  ))
                  as VideoClipOpened)
              .clip;
      final a = paintable();
      final b = VideoAnimationPaintable(
        key: 'b',
        clip: other,
        firstFrame: _solid(0xFF00FF00),
        scheduler: scheduler,
      );
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      for (var ms = 0; ms < 200; ms += 16) {
        final context = AssetPaintContext(time: Duration(milliseconds: ms));
        a.advancePlayback(context);
        b.advancePlayback(context);
        await tick();
      }
      final held = scheduler.bufferedBytes;

      a.leftScreen();
      timers.elapse(Duration.zero);
      b.leftScreen();
      timers.elapse(Duration.zero);

      expect(scheduler.bufferedBytes, lessThanOrEqualTo(5 * 1024));
      expect(scheduler.bufferedBytes, lessThan(held));
      expect(scheduler.bufferedBytes, greaterThan(0), reason: 'b keeps its');
    });

    test('frames kept for a return go with the paintable, and under memory '
        'pressure', () async {
      final p = paintable();
      await play(p, 0, 200);
      p.leftScreen();
      timers.elapse(Duration.zero);
      expect(scheduler.bufferedBytes, greaterThan(0));

      scheduler.releaseIdle();
      expect(scheduler.bufferedBytes, 0, reason: 'memory pressure');

      p
        ..playbackResumed()
        ..advancePlayback(const AssetPaintContext(time: Duration(seconds: 1)));
      await play(p, 1016, 1200);
      p.leftScreen();
      timers.elapse(Duration.zero);
      expect(scheduler.bufferedBytes, greaterThan(0));

      p.dispose();
      await pumpEventQueue();
      expect(scheduler.bufferedBytes, 0, reason: 'disposed');
    });

    test('a restart does not take back the frame it held', () async {
      final p = paintable();
      addTearDown(p.dispose);
      // The second pass ends at 800 ms: past it, a pass that does not loop
      // holds its rest frame (the first: the lease goes), and a restart
      // plays from the first frame.
      for (var ms = 0; ms < 900; ms += 16) {
        p.advancePlayback(
          AssetPaintContext(time: Duration(milliseconds: ms), loop: false),
        );
        await tick();
      }
      expect(p.isHolding, isTrue);
      expect(pool.keptFrames, 0, reason: 'nothing comes back to it');

      expect(p.restart(), isTrue);
      p.advancePlayback(
        const AssetPaintContext(time: Duration(milliseconds: 900)),
      );
      expect(p.texture, isNull, reason: 'its old frame is not its first');
      expect(p.sprite, isNull);
    });
  });

  group('VideoAnimationPaintable with a texture free', () {
    late FakeFrameTextureHost host;
    late FrameTexturePool pool;

    setUp(() async {
      scheduler.dispose();
      host = FakeFrameTextureHost();
      pool = FrameTexturePool(host: host, sizeClasses: const [64]);
      await pool.warm(64, 1);
      scheduler = VideoFrameScheduler(
        engine: engine,
        atlas: VideoFrameAtlas.create(
          upload: (pixels, side) async => _solid(0xFF000000, side: 4),
          sizeClasses: const [64],
        ),
        clock: clock,
        textures: pool,
        textureWriter: FakeTextureFrameWriter(),
        startTimer: timers.start,
      );
    });
    tearDown(() => pool.dispose());

    test(
      'a compositing surface gets the texture once a frame is posted',
      () async {
        final p = paintable();
        addTearDown(p.dispose);

        for (var ms = 0; ms < 100; ms += 16) {
          p.advancePlayback(
            AssetPaintContext(time: Duration(milliseconds: ms)),
          );
          expect(p.sprite, isNull);
          await tick();
        }

        expect(
          p.texture,
          AssetTexture(
            id: host.liveIds.single,
            width: 64,
            height: 64,
            frameWidth: 16,
            frameHeight: 16,
          ),
        );
      },
    );

    // Composites from [from] to [to] ms, as a surface on screen does.
    Future<void> composite(VideoAnimationPaintable p, int from, int to) async {
      for (var ms = from; ms < to; ms += 16) {
        p.advancePlayback(AssetPaintContext(time: Duration(milliseconds: ms)));
        await tick();
      }
    }

    ui.Image? drawn(VideoAnimationPaintable p, int ms) {
      final canvas = _RecordingCanvas();
      p.paint(
        canvas,
        const Rect.fromLTWH(0, 0, 16, 16),
        AssetPaintContext(time: Duration(milliseconds: ms), animate: false),
      );
      return canvas.draws.singleOrNull?.image;
    }

    test('held with a picture, every surface draws that picture and not the '
        'texture; let go, it stays until the texture shows frames posted '
        'since', () async {
      final p = paintable();
      addTearDown(p.dispose);
      await composite(p, 0, 100);
      expect(p.texture, isNotNull);
      final picture = _solid(0xFFFF0000, side: 8);
      final mine = picture.clone();
      addTearDown(mine.dispose);

      p.holdPicture(picture);
      expect(p.texture, isNull);
      expect(drawn(p, 100)!.isCloneOf(mine), isTrue);

      p.holdPicture(null);
      // The texture may still queue frames from before the hold.
      expect(p.texture, isNull);
      expect(drawn(p, 100)!.isCloneOf(mine), isTrue);

      await composite(p, 116, 250);
      expect(p.texture, isNotNull);
      expect(picture.debugDisposed, isTrue);
    });

    test('a seek without a picture while held lets the held picture go with '
        'the hold: the clip is no longer on that frame', () async {
      final p = paintable();
      addTearDown(p.dispose);
      await composite(p, 0, 100);
      final picture = _solid(0xFFFF0000, side: 8);
      final mine = picture.clone();
      addTearDown(mine.dispose);

      p
        ..holdPicture(picture)
        ..seekPlayback(Duration.zero)
        ..holdPicture(null);

      expect(picture.debugDisposed, isTrue);
      expect(drawn(p, 100)?.isCloneOf(mine) ?? false, isFalse);
    });

    test("a seek's picture on a texture stays until frames posted after the "
        "seek's frame have pushed the older ones out", () async {
      final frames = FakeTextureFrameWriter();
      scheduler.dispose();
      scheduler = VideoFrameScheduler(
        engine: engine,
        atlas: VideoFrameAtlas.create(
          upload: (pixels, side) async => _solid(0xFF000000, side: 4),
          sizeClasses: const [64],
        ),
        clock: clock,
        textures: pool,
        textureWriter: frames,
        startTimer: timers.start,
      );
      final p = paintable();
      addTearDown(p.dispose);
      await composite(p, 0, 100);
      expect(p.texture, isNotNull);
      final picture = _solid(0xFFFF0000, side: 8);
      final mine = picture.clone();
      addTearDown(mine.dispose);

      p.seekPlayback(const Duration(milliseconds: 40), picture: picture);
      final before = frames.posts.length;
      var ms = 100;
      while (frames.posts.length - before < 2) {
        p.advancePlayback(AssetPaintContext(time: Duration(milliseconds: ms)));
        await tick();
        ms += 16;
        // The seek's frame and the one after are posted: two the texture
        // may still show older ones before.
        expect(p.texture, isNull);
        expect(drawn(p, ms)!.isCloneOf(mine), isTrue);
        if (ms > 2000) fail('no frames posted');
      }
      await composite(p, ms, ms + 200);
      expect(p.texture, isNotNull);
      expect(picture.debugDisposed, isTrue);
    });

    test('a surface that only paints keeps drawing sprites', () async {
      final p = paintable();
      addTearDown(p.dispose);

      for (var ms = 0; ms < 200; ms += 20) {
        await paintAt(p, ms);
      }

      expect(p.texture, isNull);
      expect(p.sprite, isNotNull);
      expect(pool.idleTextures, 1);
    });
  });

  group('VideoAnimationPaintable', () {
    test('says its picture size, the clip\'s', () {
      final p = paintable();
      addTearDown(p.dispose);

      expect(p.pictureSize, const Size(16, 16));
      expect(p.firstFrame.pictureSize, const Size(16, 16));
    });

    test('is animated and paints its first frame until one is drawn', () async {
      final p = paintable();
      addTearDown(p.dispose);

      expect(p.isAnimated, isTrue);
      expect(p.sprite, isNull);
      final first = _RecordingCanvas();
      p.paint(
        first,
        const Rect.fromLTWH(0, 0, 16, 16),
        const AssetPaintContext(),
      );
      expect(first.draws.single.image.width, 16);
    });

    // A sibling binding borrows the first frame, never the frame
    // the clip is at.
    test('lends its first frame as a still once frames are drawn', () async {
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms < 200; ms += 20) {
        await paintAt(p, ms);
      }

      final lent = p.firstFrame;
      final canvas = _RecordingCanvas();
      lent.paint(
        canvas,
        const Rect.fromLTWH(0, 0, 16, 16),
        const AssetPaintContext(),
      );

      expect(lent.isAnimated, isFalse);
      expect(canvas.draws.single.image.width, 16);
    });

    test('draws the lease sprite once a frame exists', () async {
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms < 200; ms += 20) {
        await paintAt(p, ms);
      }

      expect(p.sprite, isNotNull);
      final canvas = await paintAt(p, 220);
      // The page, not the still: a 4 px stub page against a 16 px still.
      expect(canvas.draws.single.image.width, 4);
      expect(canvas.draws.single.src.size, const Size(16, 16));
    });

    test('cover fills the cell with the still, cropping the overflow', () {
      final p = paintable();
      addTearDown(p.dispose);
      final canvas = _RecordingCanvas();
      const cell = Rect.fromLTWH(0, 0, 32, 16);

      p.paint(canvas, cell, const AssetPaintContext(fit: AssetFit.cover));

      // A 16 x 16 still in a 32 x 16 cell: the whole width, the middle half.
      expect(canvas.draws.single.dst, cell);
      expect(canvas.draws.single.src, const Rect.fromLTWH(0, 4, 16, 8));
    });

    test('contain keeps the still whole with bars', () {
      final p = paintable();
      addTearDown(p.dispose);
      final canvas = _RecordingCanvas();

      p.paint(
        canvas,
        const Rect.fromLTWH(0, 0, 32, 16),
        const AssetPaintContext(),
      );

      expect(canvas.draws.single.src, const Rect.fromLTWH(0, 0, 16, 16));
      expect(canvas.draws.single.dst, const Rect.fromLTWH(8, 0, 16, 16));
    });

    test('cover crops the lease sprite on its page', () async {
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms < 200; ms += 20) {
        await paintAt(p, ms);
      }
      final sprite = p.sprite!;
      final canvas = _RecordingCanvas();
      const cell = Rect.fromLTWH(0, 0, 32, 16);

      p.paint(canvas, cell, const AssetPaintContext(fit: AssetFit.cover));

      final draw = canvas.draws.single;
      expect(draw.image, same(sprite.page));
      expect(draw.dst, cell);
      expect(draw.src.width, sprite.source.width);
      expect(draw.src.height, closeTo(sprite.source.height / 2, 1e-9));
      expect(draw.src.center, sprite.source.center);
    });

    test('a step over the resume gap adds no played time', () async {
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms <= 40; ms += 20) {
        await paintAt(p, ms, loop: false);
      }
      // The clock stood still while paused and then jumped by a minute.
      await paintAt(p, 60040, loop: false);
      await paintAt(p, 60060, loop: false);

      // 60 ms played of a 100 ms clip: the pass is not over.
      expect(p.isHolding, isFalse);
    });

    test('after a resume, a stop shorter than the resume gap adds no played '
        'time', () async {
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms <= 40; ms += 20) {
        await paintAt(p, ms, loop: false);
      }
      // Held 300 ms while the clock ran on for others, then played again.
      p.playbackResumed();
      await paintAt(p, 340, loop: false);
      await paintAt(p, 360, loop: false);

      // 60 ms played of a 100 ms clip: the pass is not over.
      expect(p.isHolding, isFalse);
    });

    test('rewind plays from the first frame in the middle of a pass, and '
        'shows the still until the new pass has a frame', () async {
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms <= 80; ms += 20) {
        await paintAt(p, ms, loop: false);
      }
      expect(p.sprite, isNotNull);

      p.rewind();

      expect(p.sprite, isNull, reason: 'the frame the pass was at is gone');
      // 80 ms played before the rewind; 60 ms more would end a pass that went
      // on from there.
      for (var ms = 100; ms <= 160; ms += 20) {
        await paintAt(p, ms, loop: false);
      }
      expect(p.isHolding, isFalse);
    });

    test(
      'a pass that does not loop holds the rest frame, and restarts',
      () async {
        final p = paintable();
        addTearDown(p.dispose);
        for (var ms = 0; ms <= 400; ms += 25) {
          await paintAt(p, ms, loop: false);
        }

        expect(p.isHolding, isTrue);
        expect(p.restart(), isTrue);
        expect(p.isHolding, isFalse);
        expect(
          p.restart(),
          isFalse,
          reason: 'a pass in progress is not rewound',
        );
      },
    );

    test(
      'a holding pass with the first frame at rest shows the still',
      () async {
        final p = paintable();
        addTearDown(p.dispose);
        for (var ms = 0; ms <= 400; ms += 25) {
          await paintAt(p, ms, loop: false);
        }

        final canvas = await paintAt(p, 450, loop: false);

        expect(p.sprite, isNull);
        expect(canvas.draws.single.image.width, 16);
      },
    );

    test('with the pool full it keeps painting the still', () async {
      scheduler.dispose();
      scheduler = build(budget: 128 * 128 * 4);
      final others = [
        for (var i = 0; i < 4; i++) scheduler.acquire('o$i', clip),
      ];
      expect(others.whereType<VideoFrameLease>(), hasLength(4));
      final p = paintable();
      addTearDown(p.dispose);

      for (var ms = 0; ms < 100; ms += 20) {
        await paintAt(p, ms);
      }

      expect(p.sprite, isNull);
    });

    test('dispose frees the lease, the still and the clip once', () async {
      final p = paintable();
      for (var ms = 0; ms < 100; ms += 20) {
        await paintAt(p, ms);
      }

      p
        ..dispose()
        ..dispose();

      expect(disposed, 1);
      expect(scheduler.leaseCount, 0);
      expect(scheduler.bufferedBytes, 0);
    });

    test('leaving the screen gives the lease back after the frame, unless '
        'kept', () async {
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms < 100; ms += 20) {
        await paintAt(p, ms);
      }

      p
        ..keepFrame(keep: true)
        ..leftScreen();
      timers.elapse(Duration.zero);
      expect(scheduler.leaseCount, 1, reason: 'a held surface shows it');

      p
        ..keepFrame(keep: false)
        ..leftScreen();
      timers.elapse(Duration.zero);
      expect(scheduler.leaseCount, 0);

      await paintAt(p, 120);
      expect(scheduler.leaseCount, 1, reason: 'painted again, it leases');
    });

    test('on a slot, a clip that comes back draws the frame it left on at '
        'once', () async {
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms < 100; ms += 20) {
        await paintAt(p, ms);
      }
      expect(p.sprite, isNotNull);

      p.leftScreen();
      timers.elapse(Duration.zero);
      expect(scheduler.leaseCount, 0);
      p
        ..playbackResumed()
        ..advancePlayback(const AssetPaintContext(time: Duration(seconds: 2)));

      expect(p.sprite, isNotNull, reason: 'not its still');
    });

    test('a failed lease is never asked again and the still stays', () async {
      await engine.close(clip);
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms < 100; ms += 20) {
        await paintAt(p, ms);
      }

      expect(p.sprite, isNull);
      final canvas = await paintAt(p, 120);
      expect(canvas.draws.single.image.width, 16);
    });

    test('keeps alpha premultiplied BGRA to the screen', () async {
      scheduler.dispose();
      // The real page upload: the pages are BGRA and must be read as such.
      scheduler = VideoFrameScheduler(
        engine: engine,
        atlas: VideoFrameAtlas.create(),
        clock: clock,
        startTimer: timers.start,
      );
      final p = paintable();
      addTearDown(p.dispose);
      for (var ms = 0; ms <= 80; ms += 20) {
        await paintAt(p, ms);
      }
      Future<List<int>> centre() async {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)
          ..drawRect(
            const Rect.fromLTWH(0, 0, 16, 16),
            ui.Paint()..color = const ui.Color(0xFFFFFFFF),
          );
        p.paint(
          canvas,
          const Rect.fromLTWH(0, 0, 16, 16),
          const AssetPaintContext(time: Duration(milliseconds: 100)),
        );
        final picture = recorder.endRecording();
        final image = picture.toImageSync(16, 16);
        picture.dispose();
        final rgba = (await image.toByteData())!;
        image.dispose();
        const at = (8 * 16 + 8) * 4;
        return [for (var c = 0; c < 4; c++) rgba.getUint8(at + c)];
      }

      // Real image uploads complete outside the fake event loop, and on a
      // loaded runner later than any fixed wait. The clip loops, so keep
      // painting until frame 2's upload is the one on screen.
      var pixel = <int>[];
      for (var attempt = 0; attempt < 100; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await paintAt(p, 90);
        pixel = await centre();
        if ((pixel[1] - 71).abs() <= 2) break;
      }

      expect(p.sprite, isNotNull);
      // The fake's frame 2 is B 32, G 16, R 0 under alpha 200. Over white
      // each channel adds the 55 the alpha lets through: R 55, G 71, B 87.
      expect(pixel, [closeTo(55, 2), closeTo(71, 2), closeTo(87, 2), 255]);
    });
  });
}

/// Posts every job and keeps the index of the fake's frame it carried (its
/// blue over 16), read from the source while the job is being written.
final class _IndexRecordingWriter implements TextureFrameWriter {
  final List<int> indices = [];

  @override
  Future<List<TextureFrameOutcome>> write(List<TextureFrameJob> jobs) async {
    for (final job in jobs) {
      final source = job.source as VideoFrameSource;
      indices.add(source.pixelsOf(job.frame)!.first ~/ 16);
    }
    return [for (final _ in jobs) TextureFrameOutcome.posted];
  }
}
