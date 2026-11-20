import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

/// The viewer is 400 x 800; the items are 400 x 300, so a picture rests at
/// (0, 250) to (400, 550).
const viewerSize = Size(400, 800);
const fittedRect = Rect.fromLTWH(0, 250, 400, 300);
const originRect = Rect.fromLTWH(20, 600, 120, 90);

MediaKey photoKey(int index) => MediaKey.remote('photo-$index');

MediaKey videoKey(int index) => MediaKey.remote('video-$index');

/// A viewer over three photos (or the given [items]), the first with an
/// origin; with [videoDuration] a fake player backend plays the videos.
final class ViewerHarness {
  ViewerHarness({
    int count = 3,
    List<GalleryItem>? items,
    Duration? videoDuration,
    bool autoFirstFrame = true,
    bool autoPrepare = true,
    Duration? originPosition,
    Set<int>? loaded,
  }) {
    producer = FakeAssetProducer();
    clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    scope = AssetCacheScope(producer: producer, clock: clock);
    source = FakeGallerySource(
      items ??
          [
            for (var i = 0; i < count; i++)
              GalleryItem(photoKey(i), size: const Size(1200, 900)),
          ],
      loaded: loaded,
    );
    bridge = FakeOriginBridge({
      0: GalleryOrigin(
        rect: originRect,
        radius: const BorderRadius.all(Radius.circular(12)),
        clip: const Rect.fromLTWH(0, 100, 400, 600),
        position: originPosition,
      ),
    });
    if (videoDuration != null) {
      backend = FakePlayerBackend(
        duration: videoDuration,
        autoFirstFrame: autoFirstFrame,
        autoPrepare: autoPrepare,
      );
      players = PlayerPool(backend: backend!);
    }
  }

  /// Videos 400 x 300 like the photos.
  static List<GalleryItem> videos(int count, {bool hasAudio = true}) => [
    for (var i = 0; i < count; i++)
      GalleryItem(
        videoKey(i),
        kind: GalleryMediaKind.video,
        size: const Size(1200, 900),
        hasAudio: hasAudio,
      ),
  ];

  FakePlayerBackend? backend;
  PlayerPool? players;
  final ViewerSpeeds speeds = ViewerSpeeds();
  final List<bool> fullscreen = [];

  late final FakeAssetProducer producer;
  late final PlaybackClock clock;
  late final AssetCacheScope scope;
  late final FakeGallerySource source;
  late final FakeOriginBridge bridge;
  int closed = 0;
  final List<double> backdrop = [];

  Future<void> pump(
    WidgetTester tester, {
    ViewerPolicy policy = ViewerPolicy.$Android,
    ViewerChrome? chrome,
    bool open = true,
    bool firstFrameOnly = false,
    List<ViewerQuality> Function(int index, GalleryItem item)? qualitiesOf,
    ViewerController? controller,
    TextStyle? hostTextStyle,
    Duration? Function(int index, GalleryItem item)? videoStartOf,
    void Function(int index, GalleryItem item, Duration position)? onVideoLeft,
  }) async {
    tester.view.physicalSize = viewerSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() {
      scope.dispose();
      clock.dispose();
      source.dispose();
      players?.dispose();
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: _hostStyle(
          hostTextStyle,
          MediaViewer(
            source: source,
            initialIndex: 0,
            bridge: bridge,
            policy: policy,
            scope: scope,
            onClosed: () => closed++,
            onBackdropScale: backdrop.add,
            chrome: chrome,
            players: players,
            speeds: speeds,
            qualitiesOf: qualitiesOf,
            onFullscreenChanged: fullscreen.add,
            controller: controller,
            videoStartOf: videoStartOf,
            onVideoLeft: onVideoLeft,
          ),
        ),
      ),
    );
    if (firstFrameOnly) return;
    await tester.pump();
    if (open)
      await tester.pump(policy.openDuration + const Duration(milliseconds: 1));
  }

  static Widget _hostStyle(TextStyle? style, Widget child) =>
      style == null ? child : DefaultTextStyle(style: style, child: child);

  /// [ViewerPolicy.$Android] with its video choices changed as given.
  static ViewerPolicy android({
    ViewerVideoStart? start,
    ViewerOriginReturn? originReturn,
    ViewerLoopOpen? loopOpen,
  }) => ViewerPolicy.$Android.copyWith(
    video: ViewerPolicy.$Android.video.copyWith(
      start: start,
      originReturn: originReturn,
      loopOpen: loopOpen,
    ),
  );

  /// The binding [cardLoop] attached last.
  late AssetBinding card;

  /// Attaches the surface's own loop of [key], as a list item that shows it
  /// playing does, and plays it as [frames] with a picture of [pictureSize];
  /// returns its playback.
  FakeAssetPaintable cardLoop(
    MediaKey key,
    List<Duration> frames, {
    Size? pictureSize,
  }) {
    const profile = AssetProfile(animate: true);
    card = scope.attach(
      key,
      AssetPresets.animation(size: originRect.size, profile: profile).spec,
      profile,
    );
    return producer.last.advance(
      AssetStage.full,
      tier: AssetTier.animated,
      frames: frames,
      pictureSize: pictureSize,
    );
  }

  MediaViewerState state(WidgetTester tester) =>
      tester.state<MediaViewerState>(find.byType(MediaViewer));

  ViewerPhotoPageState page(WidgetTester tester) =>
      tester.state<ViewerPhotoPageState>(find.byType(ViewerPhotoPage));

  /// The page of the item at [index], shown or kept offstage.
  ViewerPhotoPageState pageAt(WidgetTester tester, int index) => tester
      .stateList<ViewerPhotoPageState>(
        find.byType(ViewerPhotoPage, skipOffstage: false),
      )
      .firstWhere(
        (page) =>
            page.context
                .findAncestorWidgetOfExactType<GalleryPageScope>()
                ?.index ==
            index,
      );

  PlayerLease lease(WidgetTester tester) => state(tester).videoLease!;

  FakePlayerEngine engine(int index) => backend!.latestFor(videoKey(index))!;

  Rect morphRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('mpx-viewer-morph')));
}
