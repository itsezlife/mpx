import 'dart:async';

import 'package:flutter/material.dart' show kMinInteractiveDimension;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

// The picture rests at (0, 250) to (400, 550) in a 400 x 800 viewer.
const _rightThird = Offset(350, 400);
const _leftThird = Offset(50, 400);
// Above the play button in the middle.
const _middle = Offset(200, 300);

Future<void> _doubleTap(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(at);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

// The controls read the playhead every frame while a video plays, so the
// tree never settles by itself: pump a second of frames instead.
// Whether the player's picture shows: its texture, fully opaque.
bool _playerShows(WidgetTester tester) {
  final textures = find.byType(Texture);
  if (textures.evaluate().isEmpty) return false;
  final opacity = tester.widget<Opacity>(
    find.ancestor(of: textures.first, matching: find.byType(Opacity)).first,
  );
  return opacity.opacity == 1;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('opening a video', () {
    testWidgets('with start at the origin, starts at the origin position; '
        'the bubble frame stays until the first frame', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
        autoFirstFrame: false,
        originPosition: const Duration(seconds: 12),
      );
      await harness.pump(
        tester,
        policy: ViewerHarness.android(start: ViewerVideoStart.origin),
      );

      final engine = harness.engine(0);
      expect(engine.preparedFrom, const Duration(seconds: 12));
      expect(engine.state.value.playing, isTrue);
      expect(find.byType(PlayerView), findsOneWidget);
      expect(find.byType(Texture), findsNothing);

      engine.renderFirstFrame();
      await tester.pump();
      expect(_playerShows(tester), isFalse, reason: 'not moving yet');

      engine.advance(const Duration(milliseconds: 40));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_playerShows(tester), isTrue);
    });

    testWidgets('the morph starts at once with the origin\'s picture and '
        'the player is leased once it is over; the picture shows until the '
        'player moves', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
        autoFirstFrame: false,
      );
      await harness.pump(tester, open: false);
      await tester.pump(const Duration(milliseconds: 16));

      // The first frames move the morph, and no player exists yet.
      expect(harness.morphRect(tester), isNot(originRect));
      expect(harness.backend!.created, isEmpty, reason: 'not during the morph');

      await tester.pump(const Duration(milliseconds: 200));
      expect(harness.state(tester).isOpen, isTrue);
      expect(harness.backend!.created, isNotEmpty, reason: 'once it is over');
      final engine = harness.engine(0);
      expect(engine.state.value.playing, isTrue);

      // Its first frame, standing at 0: still the origin's picture.
      engine.renderFirstFrame();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_playerShows(tester), isFalse);

      engine.advance(const Duration(milliseconds: 40));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_playerShows(tester), isTrue);
    });

    testWidgets('closing hands the position back to the origin', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
        originPosition: const Duration(seconds: 12),
      );
      await harness.pump(
        tester,
        policy: ViewerHarness.android(start: ViewerVideoStart.origin),
      );
      harness.engine(0).advance(const Duration(seconds: 3));

      unawaited(harness.state(tester).close());
      await _settle(tester);

      expect(harness.bridge.handedBack, [(0, const Duration(seconds: 15))]);
      expect(harness.engine(0).state.value.playing, isFalse);
    });

    testWidgets('a GIF loops on the software path with no controls', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: [
          GalleryItem(
            photoKey(0),
            kind: GalleryMediaKind.animation,
            size: const Size(1200, 900),
          ),
        ],
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester);

      expect(harness.state(tester).videoLease, isNull);
      expect(harness.backend!.created, isEmpty);
      expect(find.byType(ViewerVideoControls), findsNothing);
      final views = tester.widgetList<ContentView>(find.byType(ContentView));
      expect(views, isNotEmpty);
      for (final view in views) {
        expect(view.preset.profile.animate, isTrue);
        expect(view.preset.profile.loop, isTrue);
      }
    });

    testWidgets('paging to another video plays it and leaves the first', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(2),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester);

      await tester.dragFrom(const Offset(300, 300), const Offset(-300, 0));
      await _settle(tester);

      expect(harness.state(tester).index, 1);
      expect(harness.players!.soundOwner, videoKey(1));
      expect(harness.engine(0).state.value.playing, isFalse);
    });
  });

  group('the surface\'s own loop of the content', () {
    final seconds = List.filled(60, const Duration(seconds: 1));

    testWidgets('by default the player starts at the beginning, wherever '
        'the origin and its loop are', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
        originPosition: const Duration(seconds: 12),
      );
      harness
          .cardLoop(videoKey(0), seconds)
          .seekPlayback(const Duration(seconds: 4));

      await harness.pump(tester);

      expect(harness.engine(0).preparedFrom, anyOf(isNull, Duration.zero));
    });

    testWidgets('with start at the origin and no origin position, the '
        'player starts where the loop is', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      harness
          .cardLoop(videoKey(0), seconds)
          .seekPlayback(const Duration(seconds: 4));

      await harness.pump(
        tester,
        policy: ViewerHarness.android(start: ViewerVideoStart.origin),
      );

      expect(harness.engine(0).preparedFrom, const Duration(seconds: 4));
    });

    testWidgets('the host\'s record of where the item was left wins, and '
        'hears where it is left again', (tester) async {
      final left = <(int, Duration)>[];
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(
        tester,
        videoStartOf: (index, item) => const Duration(seconds: 9),
        onVideoLeft: (index, item, position) => left.add((index, position)),
      );
      expect(harness.engine(0).preparedFrom, const Duration(seconds: 9));
      harness.engine(0).advance(const Duration(seconds: 3));

      unawaited(harness.state(tester).close());
      await _settle(tester);

      expect(left, [(0, const Duration(seconds: 12))]);
    });

    testWidgets('closing at the player moves the loop to where the player '
        'stood, with its last picture', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      final loop = harness.cardLoop(videoKey(0), seconds);
      await harness.pump(
        tester,
        policy: ViewerHarness.android(
          originReturn: ViewerOriginReturn.atPlayer,
        ),
      );
      harness.engine(0).advance(const Duration(seconds: 3));

      unawaited(harness.state(tester).close());
      await _settle(tester);
      // The player's picture is read off the UI isolate after the morph.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await _settle(tester);

      expect(loop.seeks.last, const Duration(seconds: 3));
      expect(harness.bridge.handedBack, [(0, const Duration(seconds: 3))]);
      final picture = loop.seekPictures.last;
      expect(picture, isNotNull);
      picture!.dispose();
    });

    testWidgets('the close morph moves on its first frame: the hand-back to '
        'the surface waits for its end', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      final loop = harness.cardLoop(videoKey(0), seconds);
      await harness.pump(
        tester,
        policy: ViewerHarness.android(
          originReturn: ViewerOriginReturn.atPlayer,
        ),
      );
      harness.engine(0).advance(const Duration(seconds: 3));
      final seeks = loop.seeks.length;

      unawaited(harness.state(tester).close());
      await tester.pump();
      final start = harness.morphRect(tester);
      await tester.pump(const Duration(milliseconds: 16));

      expect(harness.morphRect(tester), isNot(start));
      expect(harness.bridge.handedBack, isEmpty);
      expect(loop.seeks, hasLength(seeks));
    });

    testWidgets('closing with a restart plays the loop from its first frame', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      final loop = harness.cardLoop(videoKey(0), seconds)
        ..seekPlayback(const Duration(seconds: 4));
      await harness.pump(
        tester,
        policy: ViewerHarness.android(originReturn: ViewerOriginReturn.restart),
      );
      harness.engine(0).advance(const Duration(seconds: 3));

      unawaited(harness.state(tester).close());
      await _settle(tester);

      expect(loop.seeks, [const Duration(seconds: 4), Duration.zero]);
      expect(harness.bridge.handedBack, isEmpty);
      expect(harness.card.isPlaying, isTrue);
    });

    testWidgets('closing where it paused leaves the loop to go on from its '
        'frame', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      final loop = harness.cardLoop(videoKey(0), seconds)
        ..seekPlayback(const Duration(seconds: 4));
      await harness.pump(
        tester,
        policy: ViewerHarness.android(
          originReturn: ViewerOriginReturn.whereItPaused,
        ),
      );
      harness.engine(0).advance(const Duration(seconds: 3));

      unawaited(harness.state(tester).close());
      await _settle(tester);

      expect(loop.seeks, [const Duration(seconds: 4)]);
      expect(harness.bridge.handedBack, isEmpty);
      expect(harness.card.isPlaying, isTrue);
    });

    testWidgets('the loop stands still while the player plays the item, and '
        'plays again once the viewer closed', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      final loop = harness.cardLoop(videoKey(0), seconds);
      expect(harness.card.isPlaying, isTrue);

      await harness.pump(tester);
      expect(harness.card.isPlaying, isFalse);
      expect(harness.card.visible, isTrue);

      unawaited(harness.state(tester).close());
      await _settle(tester);

      expect(harness.card.isPlaying, isTrue);
      for (final picture in loop.seekPictures) {
        picture?.dispose();
      }
    });

    testWidgets('the close morph shows the player\'s picture', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester);

      unawaited(harness.state(tester).close());
      await tester.pump(const Duration(milliseconds: 50));

      expect(harness.state(tester).isOpen, isFalse);
      expect(find.byType(Texture), findsOneWidget);
    });
  });

  group('a video that fails', () {
    testWidgets('shows what happened and a retry over its picture, and a '
        'retry plays it again', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester);
      expect(
        find.byKey(const ValueKey('mpx-viewer-video-failed')),
        findsNothing,
      );

      harness.engine(0).fail(StateError('the decoder stopped'));
      await tester.pump();

      const strings = ViewerVideoStrings();
      expect(find.text(strings.failed), findsOneWidget);
      expect(find.text(strings.retry), findsOneWidget);
      final created = harness.backend!.created.length;

      await tester.tap(find.text(strings.retry));
      // Past the page's double-tap window, which holds a single tap back.
      await tester.pump(const Duration(milliseconds: 400));

      expect(harness.backend!.created.length, created + 1);
      expect(find.text(strings.failed), findsNothing);
    });
  });

  group('controls', () {
    late ViewerHarness harness;

    Future<void> open(WidgetTester tester, {Duration? duration}) async {
      harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: duration ?? const Duration(seconds: 60),
      );
      await harness.pump(tester);
    }

    testWidgets('show on open and hide after 3 s of playing', (tester) async {
      await open(tester);
      expect(harness.state(tester).controlsVisible, isTrue);

      await tester.pump(const Duration(milliseconds: 2900));
      expect(harness.state(tester).controlsVisible, isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      expect(harness.state(tester).controlsVisible, isFalse);
    });

    testWidgets('stay while paused', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-viewer-play')));
      await tester.pump();
      expect(harness.lease(tester).state.value.playing, isFalse);

      await tester.pump(const Duration(seconds: 5));
      expect(harness.state(tester).controlsVisible, isTrue);
    });

    testWidgets('the seek bar previews while dragged and seeks on release', (
      tester,
    ) async {
      await open(tester);
      final bar = tester.getRect(
        find.byKey(const ValueKey('mpx-viewer-seek-bar')),
      );
      final gesture = await tester.startGesture(bar.centerLeft);
      await gesture.moveBy(Offset(bar.width / 2, 0));
      await tester.pump();

      expect(find.byKey(const ValueKey('mpx-viewer-seek-preview')), findsOne);
      expect(harness.lease(tester).position, Duration.zero);

      await gesture.up();
      await tester.pump();
      expect(harness.lease(tester).position.inSeconds, closeTo(30, 1));
      expect(
        find.byKey(const ValueKey('mpx-viewer-seek-preview')),
        findsNothing,
      );
    });

    testWidgets('the speed panel sets the speed, kept per item', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-viewer-speed')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey(('mpx-viewer-speed-preset', 2.0))),
      );
      await tester.pump();

      expect(harness.lease(tester).state.value.speed, 2);
      expect(
        harness.speeds.speedFor(videoKey(0), ViewerSpeedMemory.perItem),
        2,
      );
      expect(
        harness.speeds.speedFor(videoKey(1), ViewerSpeedMemory.perItem),
        1,
      );
    });

    testWidgets('the seek bar keeps its length as the time and the speed '
        'change', (tester) async {
      await open(tester);
      Rect bar() =>
          tester.getRect(find.byKey(const ValueKey('mpx-viewer-seek-bar')));
      final before = bar();

      harness.engine(0).advance(const Duration(seconds: 12));
      await tester.pump(const Duration(milliseconds: 50));
      expect(bar(), before);

      await tester.tap(find.byKey(const ValueKey('mpx-viewer-speed')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey(('mpx-viewer-speed-preset', 1.5))),
      );
      await tester.pump();
      expect(bar(), before);
    });

    testWidgets('the speed panel names the speed beside its slider', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-viewer-speed')));
      await tester.pump();

      final value = find.byKey(const ValueKey('mpx-viewer-speed-value'));
      expect(find.descendant(of: value, matching: find.text('1x')), findsOne);
      final slider = tester.getRect(
        find.byKey(const ValueKey('mpx-viewer-speed-slider')),
      );
      expect(tester.getRect(value).center.dy, closeTo(slider.center.dy, 1));
      expect(find.byKey(const ValueKey('mpx-viewer-seek-bar')), findsOne);
    });

    for (final policy in [
      ViewerPolicy.$Android,
      // Controls show on open here too, so the panel can be opened.
      ViewerPolicy.$IOS.copyWith(
        video: ViewerPolicy.$IOS.video.copyWith(controlsVisibleOnOpen: true),
      ),
    ]) {
      testWidgets('each speed preset is a 48 px target that takes a tap at '
          'its edge (${policy.openStyle.name})', (tester) async {
        harness = ViewerHarness(
          items: ViewerHarness.videos(1),
          videoDuration: const Duration(seconds: 60),
        );
        await harness.pump(tester, policy: policy);
        await tester.tap(find.byKey(const ValueKey('mpx-viewer-speed')));
        await tester.pump();

        final rects = <Rect>[];
        for (final preset in policy.video.speed.presets) {
          final target = find.byKey(
            ValueKey(('mpx-viewer-speed-preset', preset)),
          );
          final rect = tester.getRect(target);
          expect(rect.width, greaterThanOrEqualTo(kMinInteractiveDimension));
          expect(rect.height, greaterThanOrEqualTo(kMinInteractiveDimension));
          for (final other in rects) {
            expect(rect.overlaps(other), isFalse, reason: '$preset');
          }
          rects.add(rect);

          await tester.tapAt(rect.topLeft + const Offset(2, 2));
          await tester.pump();
          expect(harness.lease(tester).state.value.speed, preset);
        }
        expect(
          tester
              .getSize(find.byKey(const ValueKey('mpx-viewer-speed-slider')))
              .height,
          greaterThanOrEqualTo(kMinInteractiveDimension),
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('mpx-viewer-seek-bar')))
              .height,
          greaterThanOrEqualTo(kMinInteractiveDimension),
        );
      });
    }

    testWidgets('its text is styled whatever the host puts above it', (
      tester,
    ) async {
      harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      // What a text with no style of its own inherits under an app that
      // gives none: the framework's warning style.
      await harness.pump(
        tester,
        hostTextStyle: const TextStyle(
          color: Color(0xFFFFFF00),
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.double,
        ),
      );

      final time = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const ValueKey('mpx-viewer-time')),
          matching: find.byType(RichText),
        ),
      );
      final style = time.text.style!;
      expect(style.decoration, anyOf(isNull, TextDecoration.none));
      expect(style.color, isNot(const Color(0xFFFFFF00)));
    });

    testWidgets('a quality moves the player to its media at the same place', (
      tester,
    ) async {
      harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      const low = MediaKey.remote('video-0-480');
      await harness.pump(
        tester,
        qualitiesOf: (index, item) => [
          ViewerQuality(label: 'Auto', key: item.key),
          const ViewerQuality(label: '480p', key: low),
        ],
      );
      harness.engine(0).advance(const Duration(seconds: 7));

      await tester.tap(find.byKey(const ValueKey('mpx-viewer-quality')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey(('mpx-viewer-quality-item', '480p'))),
      );
      await tester.pump();

      final lease = harness.lease(tester);
      expect(lease.key, low);
      expect(lease.position, const Duration(seconds: 7));
      expect(lease.state.value.playing, isTrue);
    });
  });

  group('double tap', () {
    testWidgets('seeks 10 s in the outer thirds, zooms in the middle', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester);
      harness.engine(0).advance(const Duration(seconds: 20));

      await _doubleTap(tester, _rightThird);
      expect(harness.lease(tester).position, const Duration(seconds: 30));

      await _doubleTap(tester, _leftThird);
      expect(harness.lease(tester).position, const Duration(seconds: 20));

      await _doubleTap(tester, _middle);
      expect(harness.page(tester).zoom, 3);
    });

    testWidgets('a video of 15 s or less zooms instead', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 15),
      );
      await harness.pump(tester);

      await _doubleTap(tester, _rightThird);
      expect(harness.lease(tester).position, Duration.zero);
      expect(harness.page(tester).zoom, 3);
    });
  });

  group('loop rule', () {
    testWidgets('a video up to 30 s loops', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 20),
      );
      await harness.pump(tester);
      expect(harness.lease(tester).state.value.looping, isTrue);
    });

    testWidgets('a longer one ends at its start, paused, controls shown', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester);
      expect(harness.lease(tester).state.value.looping, isFalse);
      await tester.pump(const Duration(seconds: 4));
      expect(harness.state(tester).controlsVisible, isFalse);

      harness.engine(0).advance(const Duration(seconds: 61));
      await tester.pump();

      final lease = harness.lease(tester);
      expect(lease.state.value.playing, isFalse);
      expect(lease.position, Duration.zero);
      expect(harness.state(tester).controlsVisible, isTrue);
    });
  });

  test('time reads m:ss, and h:mm:ss from an hour', () {
    expect(formatViewerTime(const Duration(seconds: 65)), '1:05');
    expect(formatViewerTime(const Duration(hours: 1, seconds: 5)), '1:00:05');
  });
}
