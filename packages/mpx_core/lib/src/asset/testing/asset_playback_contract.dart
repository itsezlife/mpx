import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/src/asset/asset_paintable.dart';
import 'package:mpx_core/src/asset/asset_playback_phase.dart';
import 'package:mpx_core/src/asset/asset_profile.dart';

/// What an [AssetPlaybackContract] run needs besides the paintable: the
/// durations of its frames and a way to paint it and read which frame that
/// drew.
final class AssetPlaybackHarness {
  /// Creates a harness around [paintable], a sequence of [frameDurations].
  const AssetPlaybackHarness({
    required this.paintable,
    required this.frameDurations,
    required this.frameAt,
  });

  /// The animated paintable under test, fresh: no pass started.
  final AssetPaintable paintable;

  /// How long each frame of its sequence is shown, in order.
  final List<Duration> frameDurations;

  /// Paints [paintable] at [time] with the given context flags and returns the
  /// index of the frame that was drawn. An adapter that decodes ahead settles
  /// before it answers. The flags default to a surface that animates, does not
  /// loop and rests on the first frame; the contract names every other flag.
  /// [phase] is the content's shared phase the paint carries, or null.
  final Future<int> Function(
    Duration time, {
    bool animate,
    bool loop,
    AssetRestFrame rest,
    AssetPlaybackPhase? phase,
  })
  frameAt;
}

/// The playback contract every animated [AssetPaintable] meets: one pass,
/// holding a rest frame when it does not loop, a restart, and the phase it
/// shares with the other playbacks of its content.
///
/// Frames are probed only at their boundaries, in order, as a clock delivers
/// them: a sequence that decodes one frame at a time shows one frame per
/// paint.
abstract final class AssetPlaybackContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(FutureOr<AssetPlaybackHarness> Function() create) {
    group('AssetPaintable playback contract', () {
      late AssetPlaybackHarness h;
      // The clock is at one second when the sequence is first seen.
      const start = Duration(seconds: 1);

      setUp(() async => h = await create());
      tearDown(() => h.paintable.dispose());

      // The times at which frame 0..n-1 begin, and the end of the pass.
      List<Duration> boundaries() {
        final times = <Duration>[start];
        for (final d in h.frameDurations) {
          times.add(times.last + d);
        }
        return times;
      }

      Future<void> playPass({bool loop = false, AssetRestFrame? rest}) async {
        final at = boundaries();
        for (var i = 0; i < h.frameDurations.length; i++) {
          expect(
            await h.frameAt(at[i], loop: loop),
            i,
            reason: 'frame $i at ${at[i]}',
          );
        }
        // Past the last frame's duration.
        await h.frameAt(
          at.last,
          loop: loop,
          rest: rest ?? AssetRestFrame.first,
        );
      }

      test('is animated and not holding before a pass', () {
        expect(h.paintable.isAnimated, isTrue);
        expect(h.paintable.isHolding, isFalse);
      });

      test(
        'a pass that loops wraps to the first frame and never holds',
        () async {
          await playPass(loop: true);

          expect(h.paintable.isHolding, isFalse);
          expect(await h.frameAt(boundaries().last, loop: true), 0);
        },
      );

      test(
        'a pass that does not loop holds the first frame by default',
        () async {
          await playPass();

          expect(h.paintable.isHolding, isTrue);
          expect(await h.frameAt(boundaries().last, loop: false), 0);
          expect(
            await h.frameAt(boundaries().last + const Duration(seconds: 9)),
            0,
          );
        },
      );

      test(
        'a pass that does not loop holds the last frame when asked to',
        () async {
          await playPass(rest: AssetRestFrame.last);

          expect(h.paintable.isHolding, isTrue);
          expect(
            await h.frameAt(
              boundaries().last + const Duration(seconds: 9),
              rest: AssetRestFrame.last,
            ),
            h.frameDurations.length - 1,
          );
        },
      );

      test('restart does nothing before the pass ends, and never rewinds a '
          'running one', () async {
        expect(h.paintable.restart(), isFalse);
        expect(await h.frameAt(start), 0);
        final at = boundaries();
        expect(await h.frameAt(at[1]), 1);

        expect(h.paintable.restart(), isFalse);

        expect(await h.frameAt(at[2]), 2);
      });

      test(
        'restart after a held pass plays another, from the first frame',
        () async {
          await playPass(rest: AssetRestFrame.last);
          expect(h.paintable.isHolding, isTrue);

          expect(h.paintable.restart(), isTrue);
          expect(h.paintable.isHolding, isFalse);
          expect(
            h.paintable.restart(),
            isFalse,
            reason: 'it was running again',
          );

          // The new pass counts from the first paint that animates after it.
          const again = Duration(seconds: 20);
          expect(await h.frameAt(again), 0);
          expect(await h.frameAt(again + h.frameDurations[0]), 1);
        },
      );

      test('the new pass holds again when it ends', () async {
        await playPass();
        h.paintable.restart();

        const again = Duration(seconds: 20);
        var t = again;
        for (var i = 0; i < h.frameDurations.length; i++) {
          expect(await h.frameAt(t), i);
          t += h.frameDurations[i];
        }
        await h.frameAt(t);

        expect(h.paintable.isHolding, isTrue);
      });

      test('a paint that loops wakes a holding paintable', () async {
        await playPass();
        expect(h.paintable.isHolding, isTrue);

        await h.frameAt(const Duration(seconds: 30), loop: true);

        expect(h.paintable.isHolding, isFalse);
      });

      group('the shared phase', () {
        late AssetPlaybackPhase phase;
        final other = Object();

        setUp(() => phase = AssetPlaybackPhase());

        test('a playback that starts takes the phase another one is at, '
            'and plays on in step', () async {
          final at = boundaries();
          // Another playback of the content entered frame 2 a moment ago.
          phase.report(other, at[2] - start, start);

          expect(await h.frameAt(start, loop: true, phase: phase), 2);
          expect(
            await h.frameAt(
              start + h.frameDurations[2],
              loop: true,
              phase: phase,
            ),
            0,
            reason: 'its pass ends where the other one\'s does',
          );
        });

        test('it reports where it is in its pass', () async {
          final at = boundaries();
          await h.frameAt(start, loop: true, phase: phase);
          await h.frameAt(at[1], loop: true, phase: phase);

          expect(phase.positionFor(other, at[1]), at[1] - start);
        });

        test('a playback painted again after the clock ran on without it '
            'takes the phase', () async {
          final at = boundaries();
          await h.frameAt(start, loop: true, phase: phase);
          expect(await h.frameAt(at[1], loop: true, phase: phase), 1);

          // Drawn over for a while; another playback went on meanwhile.
          final back = at[1] + const Duration(seconds: 5);
          phase.report(other, at[2] - start, back);

          expect(await h.frameAt(back, loop: true, phase: phase), 2);
        });

        test(
          'a playback its binding resumed goes on from its own frame',
          () async {
            final at = boundaries();
            await h.frameAt(start, loop: true, phase: phase);
            expect(await h.frameAt(at[1], loop: true, phase: phase), 1);

            final back = at[1] + const Duration(seconds: 5);
            phase.report(other, at[2] - start, back);
            h.paintable.playbackResumed();

            expect(await h.frameAt(back, loop: true, phase: phase), 1);
          },
        );

        test('a rewound playback plays its own pass', () async {
          final at = boundaries();
          phase.report(other, at[2] - start, start);
          h.paintable.rewind();

          expect(await h.frameAt(start, loop: true, phase: phase), 0);
        });

        test(
          'with nobody else to follow it starts from its first frame',
          () async {
            final at = boundaries();
            expect(await h.frameAt(start, loop: true, phase: phase), 0);
            expect(await h.frameAt(at[1], loop: true, phase: phase), 1);
          },
        );
      });

      test(
        'a paint that does not animate neither starts nor ends a pass',
        () async {
          await h.frameAt(start, animate: false);
          await h.frameAt(start + const Duration(seconds: 30), animate: false);
          expect(h.paintable.isHolding, isFalse);

          // The pass begins at the first paint that animates.
          const seen = Duration(seconds: 40);
          expect(await h.frameAt(seen), 0);
          expect(await h.frameAt(seen + h.frameDurations[0]), 1);
        },
      );
    });
  }

  /// Paints [paintable] into a recorder with the given flags; for adapters
  /// that answer with the frame they drew by another route.
  static void paintOnce(
    AssetPaintable paintable,
    Duration time, {
    bool animate = true,
    bool loop = true,
    AssetRestFrame rest = AssetRestFrame.first,
    AssetPlaybackPhase? phase,
  }) {
    final recorder = PictureRecorder();
    paintable.paint(
      Canvas(recorder),
      const Rect.fromLTWH(0, 0, 16, 16),
      AssetPaintContext(
        time: time,
        animate: animate,
        loop: loop,
        restFrame: rest,
        phase: phase,
      ),
    );
    recorder.endRecording().dispose();
  }
}
