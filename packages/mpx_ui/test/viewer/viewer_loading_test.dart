import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'viewer_harness.dart';

void main() {
  group('loading rules', () {
    test('Android: a 64 dp control, an arc of the bytes for photos, the '
        'spinner after '
        '500 ms fading in 200 ms, the player in 200 ms (100 handed over)', () {
      const rules = ViewerPolicy.$Android;
      expect(rules.loading, same(ViewerLoadingRules.$Android));
      final loading = rules.loading;
      expect(loading.status.diameter, 64);
      expect(loading.status.discColor, const Color(0x66000000));
      expect(loading.status.arcStroke, 3);
      expect(loading.status.spinPeriod, const Duration(milliseconds: 3000));
      expect(
        loading.status.smoothing.duration,
        const Duration(milliseconds: 300),
      );
      expect(loading.status.morphDuration, const Duration(milliseconds: 200));
      expect(loading.photoProgress, ViewerPhotoProgress.arc);
      expect(loading.photoProgressDelay, Duration.zero);
      expect(loading.hideStatusUntilCentral, isTrue);
      expect(loading.bufferingDelay, const Duration(milliseconds: 500));
      expect(loading.bufferingFade, const Duration(milliseconds: 200));
      expect(loading.playerFadeIn, const Duration(milliseconds: 200));
      expect(loading.playerFadeInHandedOver, const Duration(milliseconds: 100));
    });

    test('iOS: a 50 pt control on black at 0.5, an arc for photos, the '
        'player in 100 ms', () {
      final loading = ViewerPolicy.$IOS.loading;
      expect(loading.status.diameter, 50);
      expect(
        loading.status.discColor,
        const Color.from(alpha: 0.5, red: 0, green: 0, blue: 0),
      );
      expect(loading.photoProgress, ViewerPhotoProgress.arc);
      expect(loading.photoProgressDelay, Duration.zero);
      expect(loading.hideStatusUntilCentral, isTrue);
      expect(loading.bufferingDelay, const Duration(milliseconds: 500));
      expect(loading.bufferingFade, const Duration(milliseconds: 200));
      expect(loading.playerFadeIn, const Duration(milliseconds: 100));
      expect(loading.playerFadeInHandedOver, const Duration(milliseconds: 100));
    });

    test('desktop: a 50 px control on #00000056, a photo arc after 350 ms, '
        'the spinner fading in 500 ms, the player at once', () {
      final loading = ViewerPolicy.$Desktop.loading;
      expect(loading.status.diameter, 50);
      expect(loading.status.discColor, const Color(0x56000000));
      expect(loading.status.arcStroke, 3);
      expect(loading.photoProgress, ViewerPhotoProgress.arc);
      expect(loading.photoProgressDelay, const Duration(milliseconds: 350));
      expect(loading.hideStatusUntilCentral, isTrue);
      expect(loading.bufferingDelay, const Duration(milliseconds: 500));
      expect(loading.bufferingFade, const Duration(milliseconds: 500));
      expect(loading.playerFadeIn, Duration.zero);
      expect(loading.playerFadeInHandedOver, Duration.zero);
    });

    test('copyWith changes what it is given and keeps the rest', () {
      final changed = ViewerLoadingRules.$Android.copyWith(
        bufferingDelay: const Duration(milliseconds: 750),
        photoProgress: ViewerPhotoProgress.arc,
      );
      expect(changed.bufferingDelay, const Duration(milliseconds: 750));
      expect(changed.photoProgress, ViewerPhotoProgress.arc);
      expect(changed.bufferingFade, const Duration(milliseconds: 200));
      expect(changed.status, ViewerLoadingRules.$Android.status);

      final policy = ViewerPolicy.$Android.copyWith(loading: changed);
      expect(policy.loading, same(changed));
      expect(policy.video, same(ViewerPolicy.$Android.video));
      expect(
        ViewerPolicy.$IOS.copyWith(pageGap: 1).loading,
        same(ViewerPolicy.$IOS.loading),
      );
    });

    test('a handed-over player fades in for its own length', () {
      const loading = ViewerLoadingRules.$Android;
      expect(
        loading.playerFadeInFor(handedOver: true),
        const Duration(milliseconds: 100),
      );
      expect(
        loading.playerFadeInFor(handedOver: false),
        const Duration(milliseconds: 200),
      );
    });
  });

  group('a page', () {
    testWidgets('tells the cache its descriptor before it attaches', (
      tester,
    ) async {
      final descriptor = MediaDescriptor(
        key: photoKey(0),
        kind: MediaKind.still,
        preview: MediaPreview.raster(Uint8List.fromList(const [1, 2, 3])),
      );
      final harness = ViewerHarness(
        items: [GalleryItem(photoKey(0), descriptor: descriptor)],
      );
      final knownAtAttach = <bool>[];
      harness.producer.onProduce = (attempt) {
        if (attempt.request.key == photoKey(0)) {
          knownAtAttach.add(harness.producer.known.contains(descriptor));
        }
      };
      await harness.pump(tester);

      expect(knownAtAttach, isNotEmpty);
      expect(knownAtAttach, everyElement(isTrue));
      expect(
        harness.producer.known.where((d) => d == descriptor),
        hasLength(1),
      );
    });

    testWidgets('passes the item\'s tag to its view', (tester) async {
      const tag = AutoDownloadContext('channel');
      final harness = ViewerHarness(
        items: [GalleryItem(photoKey(0), downloadContext: tag)],
      );
      await harness.pump(tester);

      final view = tester.widget<AssetView>(
        find.byWidgetPredicate(
          (widget) => widget is AssetView && widget.content == photoKey(0),
        ),
      );
      expect(view.downloadContext, tag);
    });

    testWidgets('fits its picture to the descriptor\'s proportion when the '
        'item gives no size', (tester) async {
      final harness = ViewerHarness(
        items: [
          GalleryItem(
            photoKey(0),
            descriptor: MediaDescriptor(
              key: photoKey(0),
              kind: MediaKind.still,
              dimensions: const MediaDimensions(1200, 900),
            ),
          ),
        ],
      );
      harness.bridge.origins.clear();
      await harness.pump(tester);

      expect(tester.getRect(find.byType(AssetView)).size, fittedRect.size);
    });

    testWidgets('keeps the origin\'s frame over the preview and the '
        'thumbnail until the first frame', (tester) async {
      final harness = ViewerHarness();
      final frame = _image();
      addTearDown(frame.dispose);
      harness.bridge.frames[0] = frame;
      await harness.pump(tester);
      final attempt = harness.producer.attempts.firstWhere(
        (attempt) => attempt.request.key == photoKey(0),
      );

      attempt.advance(AssetStage.preview);
      final thumbnail = attempt.advance(AssetStage.placeholder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(MediaViewer), _drawsFrame(frame));
      // The stand-in is beneath the frame: a clear frame never leaves black.
      expect(thumbnail.paints, isNotEmpty);

      attempt.advance(AssetStage.full);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(MediaViewer), isNot(_drawsFrame(frame)));
    });

    testWidgets('without an origin frame shows the preview, then the '
        'thumbnail', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      final attempt = harness.producer.attempts.firstWhere(
        (attempt) => attempt.request.key == photoKey(0),
      );

      final preview = attempt.advance(AssetStage.preview);
      await tester.pump();
      expect(preview.paints, isNotEmpty);

      final thumbnail = attempt.advance(AssetStage.placeholder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(thumbnail.paints, isNotEmpty);
    });

    testWidgets('of a video paged away from keeps the player\'s last frame, '
        'not the preview of content still downloading', (tester) async {
      final controller = ViewerController();
      addTearDown(controller.dispose);
      final harness = ViewerHarness(
        items: ViewerHarness.videos(3),
        videoDuration: const Duration(minutes: 1),
      );
      await harness.pump(tester, controller: controller);
      final attempt = harness.producer.attempts.firstWhere(
        (attempt) => attempt.request.key == videoKey(0),
      );
      final preview = attempt.advance(AssetStage.preview);
      attempt.transfer(1000, 4000);
      // The player shows its frames over the picture.
      await tester.pump();
      harness.engine(0).advance(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester
            .widget<Opacity>(
              find.descendant(
                of: find.byKey(const ValueKey('mpx-viewer-player')),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        1,
      );

      expect(preview.paints, isNotEmpty);
      controller.jumpTo(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Paged back to, the page's picture is the frame it had, over the
      // preview, until its player is back.
      controller.jumpTo(0);
      await tester.pump();
      final view = tester.widget<AssetView>(find.byType(AssetView));
      expect(view.content, videoKey(0));
      expect(view.placeholder, isNotNull);
      expect(view.placeholderUntil, AssetStage.firstFrame);
    });
  });

  group('the status control', () {
    MediaStatus statusOf(WidgetTester tester, MediaKey key) {
      final control = find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is ViewerPageStatus && widget.content == key,
        ),
        matching: find.byType(MediaStatusControl),
      );
      return tester.widget<MediaStatusControl>(control).status!;
    }

    testWidgets('shows on the page shown only', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      final gesture = await tester.startGesture(const Offset(300, 400));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-15, 0));
        await tester.pump();
      }

      expect(
        find.byWidgetPredicate(
          (widget) => widget is AssetView && widget.content == photoKey(1),
        ),
        findsOneWidget,
      );
      final statuses = tester
          .widgetList<ViewerPageStatus>(find.byType(ViewerPageStatus))
          .map((status) => status.content);
      expect(statuses, [photoKey(0)]);
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('an animation (a GIF) that downloads shows cancel and the '
        'arc of its bytes, as a video does', (tester) async {
      final harness = ViewerHarness(
        items: [
          GalleryItem(
            photoKey(0),
            kind: GalleryMediaKind.animation,
            size: const Size(1200, 900),
          ),
        ],
      );
      await harness.pump(tester);
      final attempt = harness.producer.attempts.lastWhere(
        (attempt) => attempt.request.key == photoKey(0),
      );

      attempt
        ..waiting()
        ..transfer(25, 100);
      await tester.pump();

      final status = statusOf(tester, photoKey(0));
      expect(status.icon, MediaStatusIcon.cancel);
      expect(status.progress, 0.25);
    });

    testWidgets('Android: a photo that downloads shows an arc of its bytes '
        'on an empty disc', (tester) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      final attempt = harness.producer.last;

      attempt
        ..waiting()
        ..transfer(50, 100);
      await tester.pump();

      expect(
        statusOf(tester, photoKey(0)),
        const MediaStatus.progress(0.5, icon: MediaStatusIcon.none),
      );

      attempt.advance(AssetStage.full);
      await tester.pump();
      expect(statusOf(tester, photoKey(0)), MediaStatus.none);
    });

    testWidgets('iOS: a photo that downloads shows an arc of its bytes', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, policy: ViewerPolicy.$IOS);

      harness.producer.last.transfer(25, 100);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        statusOf(tester, photoKey(0)),
        const MediaStatus.progress(0.25, icon: MediaStatusIcon.none),
      );
    });

    testWidgets('desktop: a photo shows its arc only after 350 ms', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester, policy: ViewerPolicy.$Desktop);

      harness.producer.last.transfer(25, 100);
      await tester.pump(const Duration(milliseconds: 300));
      expect(statusOf(tester, photoKey(0)), MediaStatus.none);

      await tester.pump(const Duration(milliseconds: 60));
      expect(statusOf(tester, photoKey(0)).arc, isTrue);
    });

    testWidgets('a photo that failed offers download, which downloads', (
      tester,
    ) async {
      final harness = ViewerHarness();
      await harness.pump(tester);
      final attempts = harness.producer.attempts.length;
      harness.producer.last
        ..waiting()
        ..fail(StateError('offline'), kind: AssetFailureKind.permanent);
      await tester.pump();

      expect(
        statusOf(tester, photoKey(0)),
        const MediaStatus.icon(MediaStatusIcon.download),
      );

      await tester.tap(find.byType(MediaStatusControl));
      await tester.pump();

      expect(harness.producer.attempts.length, greaterThan(attempts));
    });

    testWidgets('only the video the viewer opened on asks for its content, '
        'wherever the source moves it', (tester) async {
      final harness = ViewerHarness(items: ViewerHarness.videos(1));
      await harness.pump(tester);
      bool asks(MediaKey key) => find
          .byWidgetPredicate(
            (widget) =>
                widget is AssetView &&
                widget.content == key &&
                widget.requestsDownload,
          )
          .evaluate()
          .isNotEmpty;
      expect(asks(videoKey(0)), isTrue);

      // The host learns of a video before it: the page shown is that one
      // now, at the index the viewer opened on.
      const earlier = GalleryItem(
        MediaKey.remote('earlier'),
        kind: GalleryMediaKind.video,
        size: Size(1200, 900),
      );
      harness.source.insert(0, earlier);
      await tester.pump();

      expect(asks(earlier.key), isFalse);
    });

    testWidgets('a video paged to without players offers its download, and '
        'a tap downloads it', (tester) async {
      final harness = ViewerHarness(items: ViewerHarness.videos(2));
      final controller = ViewerController();
      addTearDown(controller.dispose);
      await harness.pump(tester, controller: controller);
      controller.jumpTo(1);
      await tester.pump();

      final attempt = harness.producer.attempts.lastWhere(
        (attempt) => attempt.request.key == videoKey(1),
      );
      expect(attempt.demand.autoDownload(null), isNot(AutoDownload.manual));
      attempt.awaitingUser();
      await tester.pump();

      expect(
        statusOf(tester, videoKey(1)),
        const MediaStatus.icon(MediaStatusIcon.download),
      );

      await tester.tap(find.byType(MediaStatusControl));
      await tester.pump();

      final last = harness.producer.attempts.lastWhere(
        (attempt) => attempt.request.key == videoKey(1),
      );
      expect(last, isNot(same(attempt)));
    });

    testWidgets('a video the player plays has one centre control: the '
        'download radial until the first frame, then play / pause', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
        autoFirstFrame: false,
      );
      await harness.pump(tester);
      final attempt = harness.producer.attempts.lastWhere(
        (attempt) => attempt.request.key == videoKey(0),
      );
      attempt.transfer(1000, 4000);
      await tester.pump();
      final playFade = find.byKey(const ValueKey('mpx-viewer-play-fade'));
      double playOpacity() => tester.widget<Opacity>(playFade).opacity;
      Finder spinner() => find.descendant(
        of: find.byType(ViewerBufferingSpinner),
        matching: find.byType(MediaStatusControl),
      );

      // Downloading, no frame yet: cancel and the arc, never play / pause.
      final status = statusOf(tester, videoKey(0));
      expect(status.icon, MediaStatusIcon.cancel);
      expect(status.progress, 0.25);
      expect(playOpacity(), 0);
      // Past the spinner's delay the radial is still the one control.
      await tester.pump(const Duration(milliseconds: 600));
      expect(spinner(), findsNothing);

      harness.engine(0).renderFirstFrame();
      await tester.pump();
      await tester.pump();

      expect(find.byType(ViewerPageStatus), findsNothing);
      expect(playOpacity(), 1);
    });
  });

  group('the buffering spinner', () {
    Finder spinner() => find.descendant(
      of: find.byType(ViewerBufferingSpinner),
      matching: find.byType(MediaStatusControl),
    );

    double spinnerOpacity(WidgetTester tester) => tester
        .widget<FadeTransition>(
          find.descendant(
            of: find.byType(ViewerBufferingSpinner),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;

    testWidgets('never shows for a 300 ms spell', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
      );
      await harness.pump(tester);
      await tester.pump();
      final engine = harness.engine(0);

      engine.stall();
      await tester.pump(const Duration(milliseconds: 300));
      engine.resume();
      await tester.pump(const Duration(milliseconds: 600));

      expect(spinner(), findsNothing);
    });

    testWidgets('takes the play button\'s place: the centre shows one '
        'control, the spinner fading in as the button fades out', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
      );
      await harness.pump(tester);
      await tester.pump();
      final engine = harness.engine(0);
      final playFade = find.byKey(const ValueKey('mpx-viewer-play-fade'));
      double playOpacity() => tester.widget<Opacity>(playFade).opacity;
      bool playIgnored() => tester
          .widget<IgnorePointer>(
            find
                .ancestor(of: playFade, matching: find.byType(IgnorePointer))
                .first,
          )
          .ignoring;
      expect(playOpacity(), 1);

      engine.stall();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(spinnerOpacity(tester), closeTo(0.5, 0.01));
      expect(playOpacity(), closeTo(0.5, 0.01));

      await tester.pump(const Duration(milliseconds: 150));
      expect(playOpacity(), 0);
      expect(playIgnored(), isTrue);

      engine.resume();
      await tester.pump();
      expect(spinner(), findsNothing);
      expect(playOpacity(), 1);
      expect(playIgnored(), isFalse);
    });

    testWidgets('shows a 900 ms spell from 500 ms, fading in, and goes at '
        'once on resume', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
      );
      await harness.pump(tester);
      await tester.pump();
      final engine = harness.engine(0);

      engine.stall();
      await tester.pump(const Duration(milliseconds: 499));
      expect(spinner(), findsNothing);

      await tester.pump(const Duration(milliseconds: 1));
      expect(spinner(), findsOneWidget);
      expect(
        tester.widget<MediaStatusControl>(spinner()).status,
        const MediaStatus.spinner(),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(spinnerOpacity(tester), closeTo(0.5, 0.01));

      await tester.pump(const Duration(milliseconds: 300));
      engine.resume();
      await tester.pump();
      expect(spinner(), findsNothing);
    });

    testWidgets('shows for a player that has no first frame past the delay', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
        autoFirstFrame: false,
      );
      await harness.pump(tester);
      await tester.pump(const Duration(milliseconds: 600));

      expect(spinner(), findsOneWidget);

      harness.engine(0).renderFirstFrame();
      await tester.pump();
      expect(spinner(), findsNothing);
    });

    test('waits while buffering or without a first frame', () {
      const ready = PlayerState(
        phase: PlayerPhase.ready,
        firstFrameRendered: true,
      );
      expect(ViewerBufferingSpinner.waits(ready), isFalse);
      expect(
        ViewerBufferingSpinner.waits(
          ready.copyWith(phase: PlayerPhase.buffering),
        ),
        isTrue,
      );
      expect(
        ViewerBufferingSpinner.waits(
          const PlayerState(phase: PlayerPhase.preparing),
        ),
        isTrue,
      );
      expect(
        ViewerBufferingSpinner.waits(
          const PlayerState(phase: PlayerPhase.ended),
        ),
        isFalse,
      );
    });
  });

  group('the player', () {
    double playerOpacity(WidgetTester tester) => tester
        .widget<Opacity>(
          find.descendant(
            of: find.byKey(const ValueKey('mpx-viewer-player')),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;

    Future<void> playUntilMoving(
      WidgetTester tester,
      ViewerHarness harness,
    ) async {
      await tester.pump();
      harness.engine(0).advance(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('fades in over the picture for the policy\'s 200 ms', (
      tester,
    ) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
        autoFirstFrame: false,
      );
      await harness.pump(tester);
      harness.engine(0).renderFirstFrame();
      await playUntilMoving(tester, harness);

      await tester.pump(const Duration(milliseconds: 100));
      expect(playerOpacity(tester), closeTo(0.5, 0.05));
      await tester.pump(const Duration(milliseconds: 101));
      expect(playerOpacity(tester), 1);
    });

    testWidgets('a handed-over player fades in for 100 ms', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
      );
      // Warm in the pool, its first frame drawn, before the viewer takes it.
      final warm = harness.players!.lease(videoKey(0))..prepare();
      await tester.pump();
      expect(warm.state.value.firstFrameRendered, isTrue);
      warm.release();

      await harness.pump(tester);
      await playUntilMoving(tester, harness);

      await tester.pump(const Duration(milliseconds: 50));
      expect(playerOpacity(tester), closeTo(0.5, 0.05));
      await tester.pump(const Duration(milliseconds: 51));
      expect(playerOpacity(tester), 1);
    });

    testWidgets('desktop: shows at once', (tester) async {
      final harness = ViewerHarness(
        items: ViewerHarness.videos(1),
        videoDuration: const Duration(minutes: 1),
        autoFirstFrame: false,
      );
      await harness.pump(tester, policy: ViewerPolicy.$Desktop);
      harness.engine(0).renderFirstFrame();
      await playUntilMoving(tester, harness);
      await tester.pump();

      expect(playerOpacity(tester), 1);
    });
  });

  group('a video page', () {
    testWidgets('fades its player in over the stand-in and shows the '
        'spinner past the delay', (tester) async {
      final backend = FakePlayerBackend(autoFirstFrame: false);
      final players = PlayerPool(backend: backend);
      addTearDown(players.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ViewerVideoPage(
            item: GalleryItem(videoKey(0), kind: GalleryMediaKind.video),
            players: players,
            standIn: const Text('still'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.descendant(
          of: find.byType(ViewerBufferingSpinner),
          matching: find.byType(MediaStatusControl),
        ),
        findsOneWidget,
      );

      backend.latestFor(videoKey(0))!.renderFirstFrame();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final fade = tester.widget<Opacity>(
        find.ancestor(
          of: find.byType(PlayerView),
          matching: find.byType(Opacity),
        ),
      );
      expect(fade.opacity, closeTo(0.5, 0.05));
      expect(find.text('still'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 101));
      await tester.pump();
      expect(find.text('still'), findsNothing);
    });
  });

  group('changes heard while the tree builds', () {
    testWidgets('the status hears its binding change in a build, and shows it '
        'after the frame', (tester) async {
      final producer = FakeAssetProducer();
      final scope = AssetCacheScope(
        producer: producer,
        clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      );
      addTearDown(scope.dispose);
      const key = MediaKey.remote('clip');
      var tile = false;
      late StateSetter setTile;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              ViewerPageStatus(
                content: key,
                spec: const AssetSpec(pixelWidth: 400, pixelHeight: 400),
                kind: GalleryMediaKind.video,
                rules: ViewerLoadingRules.$Android,
                scope: scope,
              ),
              // Another subtree (a grid under the viewer) that builds alone.
              StatefulBuilder(
                builder: (context, setState) {
                  setTile = setState;
                  return tile
                      ? AssetView(
                          content: key,
                          scope: scope,
                          preset: const AssetPreset(
                            size: Size(100, 100),
                            spec: AssetSpec(pixelWidth: 100, pixelHeight: 100),
                            profile: AssetProfile(),
                          ),
                        )
                      : const SizedBox();
                },
              ),
            ],
          ),
        ),
      );
      producer.last.awaitingUser();
      await tester.pump();
      expect(find.bySemanticsLabel('Download'), findsOneWidget);

      // A tile of the content mounts and its picture is in memory: the page
      // shows it at once, heard while the tile builds.
      producer.onProduce = (attempt) => attempt.advance(AssetStage.full);
      setTile(() => tile = true);
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 400));
      expect(find.bySemanticsLabel('Download'), findsNothing);
    });

    testWidgets('a spinner handed another player tells its presence after '
        'the frame', (tester) async {
      final backend = FakePlayerBackend();
      final pool = PlayerPool(backend: backend);
      addTearDown(pool.dispose);
      final presence = ValueNotifier<double>(0);
      addTearDown(presence.dispose);
      final first = pool.lease(const MediaKey.remote('a'));
      final second = pool.lease(const MediaKey.remote('b'));
      Widget tree(PlayerLease lease) => Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            ValueListenableBuilder<double>(
              valueListenable: presence,
              builder: (context, value, _) => Text('$value'),
            ),
            ViewerBufferingSpinner(
              lease: lease,
              rules: ViewerLoadingRules.$Android,
              presence: presence,
            ),
          ],
        ),
      );
      await tester.pumpWidget(tree(first));
      first.prepare();
      await tester.pump();
      backend.latestFor(const MediaKey.remote('a'))!.stall();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      expect(presence.value, greaterThan(0));

      await tester.pumpWidget(tree(second));
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(presence.value, 0);
    });
  });
}

PaintPattern _drawsFrame(ui.Image frame) =>
    paints..something((method, arguments) {
      if (method != #drawImageRect) return false;
      final image = arguments.first as ui.Image;
      return image.isCloneOf(frame);
    });

ui.Image _image() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 4, 3),
    Paint()..color = const Color(0xFF00FF00),
  );
  return recorder.endRecording().toImageSync(4, 3);
}
