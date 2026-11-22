import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show kMinInteractiveDimension;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

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

ui.Image _solid(int argb) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawPaint(Paint()..color = Color(argb));
  final picture = recorder.endRecording();
  final image = picture.toImageSync(4, 3);
  picture.dispose();
  return image;
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

    testWidgets('a cold player is leased as the viewer is built, and the '
        'origin\'s picture shows until the player moves', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
        autoFirstFrame: false,
      );
      await harness.pump(tester, open: false);

      expect(harness.backend!.created, isNotEmpty, reason: 'before the morph');
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
      final views = tester.widgetList<AssetView>(find.byType(AssetView));
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

  group('a stand-in still', () {
    const still = MediaKey.remote('still-0');

    testWidgets('lies under a video page with no frame of its own until the '
        "player's first frame, so a page coming back is never black", (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: [
          GalleryItem(
            videoKey(0),
            kind: GalleryMediaKind.video,
            size: const Size(1200, 900),
            standIn: const MediaDescriptor(key: still, kind: MediaKind.still),
          ),
        ],
        videoDuration: const Duration(seconds: 10),
        autoFirstFrame: false,
      );
      await harness.pump(tester);
      final standIn = find.byWidgetPredicate(
        (w) => w is AssetView && w.content == still,
      );
      expect(standIn, findsOneWidget);
      expect(_playerShows(tester), isFalse);
      // The cache was told the still, so its key resolves.
      expect(harness.producer.known.map((d) => d.key), contains(still));
      harness.engine(0).renderFirstFrame();
      await tester.pump();
      // Playing, it moves past its first frame and shows over the still.
      harness.engine(0).advance(const Duration(milliseconds: 100));
      await _settle(tester);
      expect(_playerShows(tester), isTrue);
    });

    testWidgets('an item without one draws no extra picture', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 10),
      );
      await harness.pump(tester);
      expect(
        find.byWidgetPredicate((w) => w is AssetView && w.content == still),
        findsNothing,
      );
    });
  });

  group("a picker's videos", () {
    final picker = ViewerPolicy.$Android.copyWith(
      video: PickerViewer.videoRules(ViewerPolicy.$Android.video),
    );

    double playShown(WidgetTester tester) => tester
        .widget<Opacity>(find.byKey(const ValueKey('mpx-viewer-play-fade')))
        .opacity;

    testWidgets('a page shown waits paused at the start, play shown', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(2),
        videoDuration: const Duration(seconds: 10),
      );
      await harness.pump(tester, policy: picker);
      await _settle(tester);
      final state = harness.engine(0).state.value;
      expect(state.playing, isFalse);
      expect(state.firstFrameRendered, isTrue, reason: 'prepared');
      expect(harness.lease(tester).position, Duration.zero);
      expect(playShown(tester), 1);
      expect(
        _playerShows(tester),
        isTrue,
        reason: 'its first frame, sharp, over the blurred picture',
      );

      // Paged to, the next waits too.
      await tester.dragFrom(const Offset(300, 300), const Offset(-300, 0));
      await _settle(tester);
      expect(harness.state(tester).index, 1);
      expect(harness.engine(1).state.value.playing, isFalse);
    });

    testWidgets('played to its end it stops back at the start, play shown, '
        'with no new pass; play then plays it from the start', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 10),
      );
      await harness.pump(tester, policy: picker);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('mpx-viewer-play')));
      await tester.pump();
      final engine = harness.engine(0);
      expect(engine.state.value.playing, isTrue);
      expect(engine.state.value.looping, isFalse);

      engine.advance(const Duration(seconds: 11));
      await tester.pump();
      await _settle(tester);
      expect(engine.state.value.playing, isFalse);
      expect(harness.lease(tester).position, Duration.zero);
      expect(playShown(tester), 1);
      // No new pass by itself.
      engine.advance(const Duration(seconds: 3));
      await tester.pump();
      expect(harness.lease(tester).position, Duration.zero);

      await tester.tap(find.byKey(const ValueKey('mpx-viewer-play')));
      await tester.pump();
      expect(engine.state.value.playing, isTrue);
      engine.advance(const Duration(seconds: 2));
      await tester.pump();
      expect(harness.lease(tester).position, const Duration(seconds: 2));
    });

    testWidgets('a short video loops and autoplays under the chat viewer\'s '
        'own rules', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 10),
      );
      await harness.pump(tester);
      await _settle(tester);
      expect(harness.engine(0).state.value.playing, isTrue);
      expect(harness.engine(0).state.value.looping, isTrue);
    });
  });

  group('restart', () {
    Future<Duration> pageAwayAndBack(
      WidgetTester tester, {
      required bool restarts,
    }) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(2),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(
        tester,
        policy: ViewerPolicy.$Android.copyWith(
          video: ViewerPolicy.$Android.video.copyWith(restarts: restarts),
        ),
      );
      harness.engine(0).advance(const Duration(seconds: 7));
      await tester.pump();
      expect(harness.lease(tester).position, const Duration(seconds: 7));
      await tester.dragFrom(const Offset(300, 300), const Offset(-300, 0));
      await _settle(tester);
      expect(harness.state(tester).index, 1);
      await tester.dragFrom(const Offset(100, 300), const Offset(300, 0));
      await _settle(tester);
      expect(harness.state(tester).index, 0);
      expectThemedText(tester);
      return harness.lease(tester).position;
    }

    testWidgets('a policy that restarts plays a video paged back to from '
        'its beginning', (tester) async {
      expect(await pageAwayAndBack(tester, restarts: true), Duration.zero);
    });

    testWidgets('a policy that restarts plays a video opened again from its '
        'beginning, though its player is still warm', (tester) async {
      final policy = ViewerPolicy.$Android.copyWith(
        video: ViewerPolicy.$Android.video.copyWith(restarts: true),
      );
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester, policy: policy);
      harness.engine(0).advance(const Duration(seconds: 9));
      await tester.pump();
      harness.state(tester).close().ignore();
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());
      // Opened again over the same players: the warm player is sought back.
      await harness.pump(tester, policy: policy);
      expect(harness.lease(tester).position, Duration.zero);
    });

    testWidgets('without it, the video goes on where it was left', (
      tester,
    ) async {
      expect(
        await pageAwayAndBack(tester, restarts: false),
        const Duration(seconds: 7),
      );
    });
  });

  group('the neighbours', () {
    testWidgets('a tap open leases the player before the morph\'s first '
        'frame', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
        autoFirstFrame: false,
      );
      // Runs as the first frame ends, before anything the viewer schedules
      // for after it.
      int? createdByFirstFrame;
      tester.binding.addPostFrameCallback(
        (_) => createdByFirstFrame = harness.backend!.created.length,
      );
      await harness.pump(tester, firstFrameOnly: true);

      expect(createdByFirstFrame, 1);
      expect(harness.backend!.created.map((e) => e.key), [videoKey(0)]);
      expect(harness.engine(0).prepareCount, 1);
    });

    testWidgets('settling on a page prepares the videos beside it, paused, '
        'and gives back those that leave the window', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(5),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester);
      await tester.pump();

      final viewer = harness.state(tester);
      expect(viewer.preparedNeighbours, {1});
      expect(harness.engine(1).state.value.phase, PlayerPhase.ready);
      expect(harness.engine(1).state.value.playing, isFalse);
      expect(harness.players!.soundOwner, videoKey(0));

      await tester.dragFrom(const Offset(300, 300), const Offset(-300, 0));
      await _settle(tester);
      expect(viewer.index, 1);
      expect(viewer.preparedNeighbours, {0, 2});
      // The prepared player is the one that plays: no new engine.
      expect(harness.backend!.created.where((e) => e.key == videoKey(1)), [
        harness.engine(1),
      ]);
      expect(harness.engine(1).state.value.playing, isTrue);
      expect(harness.engine(0).state.value.playing, isFalse);
      expect(harness.engine(2).state.value.playing, isFalse);

      await tester.dragFrom(const Offset(300, 300), const Offset(-300, 0));
      await _settle(tester);
      expect(viewer.index, 2);
      expect(viewer.preparedNeighbours, {1, 3});
      expect(harness.players!.soundOwner, videoKey(2));
      // Within the pool's budget: the one left out lost its engine.
      expect(harness.players!.engineCount, 3);
      expect(harness.engine(0).isDisposed, isTrue);
    });

    testWidgets('the pool\'s prepared budget caps them, the next first', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(3),
        videoDuration: const Duration(seconds: 60),
      );
      harness.players!.budget = const PlayerBudget(prepared: 1);
      await harness.pump(tester);
      await tester.dragFrom(const Offset(300, 300), const Offset(-300, 0));
      await _settle(tester);

      expect(harness.state(tester).preparedNeighbours, {2});
    });

    testWidgets('they wait for the item shown to have its first frame', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(2),
        videoDuration: const Duration(seconds: 60),
        autoFirstFrame: false,
      );
      await harness.pump(tester);
      await tester.pump();
      expect(harness.state(tester).preparedNeighbours, isEmpty);
      expect(harness.backend!.latestFor(videoKey(1)), isNull);

      harness.engine(0).renderFirstFrame();
      await tester.pump();
      expect(harness.state(tester).preparedNeighbours, {1});
      expect(harness.engine(1).state.value.playing, isFalse);
    });

    testWidgets('closing gives them back', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(2),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(tester);
      await tester.pump();
      expect(harness.state(tester).preparedNeighbours, {1});

      unawaited(harness.state(tester).close());
      await tester.pump();
      expect(harness.state(tester).preparedNeighbours, isEmpty);
      await _settle(tester);
    });

    testWidgets('a policy without them prepares none', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(2),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(
        tester,
        policy: ViewerPolicy.$Android.copyWith(
          video: ViewerPolicy.$Android.video.copyWith(prepareNeighbours: false),
        ),
      );
      await tester.pump();

      expect(harness.state(tester).preparedNeighbours, isEmpty);
      expect(harness.backend!.latestFor(videoKey(1)), isNull);
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

      expect(loop.seeks.last, const Duration(seconds: 3));
      expect(harness.bridge.handedBack, [(0, const Duration(seconds: 3))]);
      final picture = loop.seekPictures.last;
      expect(picture, isNotNull);
      picture!.dispose();
    });

    for (final android in [true, false]) {
      testWidgets(
        '${android ? 'Android' : 'iOS'}: the loop stands on the frame the '
        'origin showed at the tap, every surface drawing that frame, with no '
        'seek; closing ${android ? 'moves it to the player with its last '
                  'picture' : 'plays it again from its first frame'}',
        (tester) async {
          final harness = ViewerHarness(
            items: ViewerHarness.videos(1),
            videoDuration: const Duration(seconds: 60),
          );
          final loop = harness.cardLoop(videoKey(0), seconds)
            ..seekPlayback(const Duration(seconds: 8));
          final shown = _solid(0xFF0000FF);
          addTearDown(shown.dispose);
          harness.bridge.frames[0] = shown;

          await harness.pump(
            tester,
            policy: android ? ViewerPolicy.$Android : ViewerPolicy.$IOS,
          );

          // Held on exactly the frame the tile showed: no seek, no advance.
          expect(loop.heldPicture!.isCloneOf(shown), isTrue);
          expect(loop.seeks, [const Duration(seconds: 8)]);
          expect(loop.playbackPosition, const Duration(seconds: 8));
          expect(harness.card.isPlaying, isFalse);

          harness.engine(0).advance(const Duration(seconds: 3));
          unawaited(harness.state(tester).close());
          await _settle(tester);

          // The held frame is let go once the seek has a picture of its own:
          // nothing from the tile's old place is drawn after landing.
          expect(loop.heldPicture, isNull);
          if (android) {
            expect(loop.seeks.last, const Duration(seconds: 3));
            expect(loop.seekPictures.last, isNotNull);
          } else {
            expect(loop.seeks.last, Duration.zero);
          }
          expect(harness.card.isPlaying, isTrue);
          for (final picture in [...loop.seekPictures, ...loop.heldPictures]) {
            picture?.dispose();
          }
        },
      );
    }

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

    testWidgets('a policy whose controls never hide by themselves keeps them '
        'over a playing video', (tester) async {
      harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(
        tester,
        policy: ViewerPolicy.$Android.copyWith(
          video: ViewerPolicy.$Android.video.copyWith(autoHides: false),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(harness.lease(tester).state.value.playing, isTrue);
      expect(harness.state(tester).controlsVisible, isTrue);
    });

    testWidgets('a policy without a centre while playing shows nothing over '
        'a playing video and the play button over a paused one', (
      tester,
    ) async {
      harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(seconds: 60),
      );
      await harness.pump(
        tester,
        policy: ViewerPolicy.$Android.copyWith(
          video: ViewerPolicy.$Android.video.copyWith(
            autoHides: false,
            centreWhilePlaying: false,
          ),
        ),
      );
      double centre() => tester
          .widgetList<Opacity>(
            find.ancestor(
              of: find.byKey(const ValueKey('mpx-viewer-play')),
              matching: find.byType(Opacity),
            ),
          )
          .map((o) => o.opacity)
          .reduce((a, b) => a * b);
      expect(harness.lease(tester).state.value.playing, isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(centre(), 0);

      harness.lease(tester).pause();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(centre(), 1);
      expectThemedText(tester);
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

    testWidgets(
      'before the player knows the length, the time reads the item\'s own',
      (tester) async {
        harness = ViewerHarness(
          items: [
            GalleryItem(
              videoKey(0),
              kind: GalleryMediaKind.video,
              size: const Size(1200, 900),
              hasAudio: true,
              descriptor: MediaDescriptor(
                key: videoKey(0),
                kind: MediaKind.video,
                duration: const Duration(seconds: 52),
              ),
            ),
          ],
          videoDuration: const Duration(seconds: 60),
          autoPrepare: false,
        );
        await harness.pump(tester);
        expect(harness.lease(tester).state.value.duration, isNull);

        String time() => tester
            .widget<Text>(find.byKey(const ValueKey('mpx-viewer-time')))
            .data!;
        expect(time(), '0:00 / 0:52');

        // The player's own length wins once it reports one.
        harness.engine(0).completePrepare();
        await tester.pump();
        expect(time(), '0:00 / 1:00');
      },
    );

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
