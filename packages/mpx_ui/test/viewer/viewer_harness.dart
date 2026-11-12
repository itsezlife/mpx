import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

/// The viewer is 400 x 800; the items are 400 x 300, so a picture rests at
/// (0, 250) to (400, 550).
const viewerSize = Size(400, 800);
const fittedRect = Rect.fromLTWH(0, 250, 400, 300);
const originRect = Rect.fromLTWH(20, 600, 120, 90);

MediaKey photoKey(int index) => MediaKey.remote('photo-$index');

/// A viewer over three photos, the first with an origin.
final class ViewerHarness {
  ViewerHarness({int count = 3}) {
    producer = FakeAssetProducer();
    clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    scope = AssetCacheScope(producer: producer, clock: clock);
    source = FakeGallerySource([
      for (var i = 0; i < count; i++)
        GalleryItem(photoKey(i), size: const Size(1200, 900)),
    ]);
    bridge = FakeOriginBridge({
      0: const GalleryOrigin(
        rect: originRect,
        radius: BorderRadius.all(Radius.circular(12)),
        clip: Rect.fromLTWH(0, 100, 400, 600),
      ),
    });
  }

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
  }) async {
    tester.view.physicalSize = viewerSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() {
      scope.dispose();
      clock.dispose();
      source.dispose();
    });
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaViewer(
          source: source,
          initialIndex: 0,
          bridge: bridge,
          policy: policy,
          scope: scope,
          onClosed: () => closed++,
          onBackdropScale: backdrop.add,
          chrome: chrome,
        ),
      ),
    );
    await tester.pump();
    if (open)
      await tester.pump(policy.openDuration + const Duration(milliseconds: 1));
  }

  MediaViewerState state(WidgetTester tester) =>
      tester.state<MediaViewerState>(find.byType(MediaViewer));

  ViewerPhotoPageState page(WidgetTester tester) =>
      tester.state<ViewerPhotoPageState>(find.byType(ViewerPhotoPage));

  Rect morphRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('mpx-viewer-morph')));
}
