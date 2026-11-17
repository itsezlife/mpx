import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

import 'viewer_harness.dart';

const _policy = ViewerPolicy.$Android;

void main() {
  late FakeAssetProducer producer;
  late PlaybackClock clock;
  late AssetCacheScope scope;
  late FakeGallerySource source;

  setUp(() {
    producer = FakeAssetProducer();
    clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    scope = AssetCacheScope(producer: producer, clock: clock);
    source = FakeGallerySource([
      for (var i = 0; i < 20; i++)
        GalleryItem(photoKey(i), size: const Size(1200, 900)),
    ]);
  });
  tearDown(() {
    scope.dispose();
    clock.dispose();
    source.dispose();
  });

  /// A host page under a navigator, 400 x 800.
  Future<void> pumpHost(WidgetTester tester, Widget surface) async {
    tester.view.physicalSize = viewerSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: viewerSize),
          child: Navigator(
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (context, _, _) => ViewerOriginScope(child: surface),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Widget thumbnail(int index, {double? height}) => Builder(
    builder: (context) => GestureDetector(
      onTap: () => MediaViewer.show(
        context,
        source: source,
        initialIndex: index,
        policy: _policy,
        scope: scope,
      ),
      child: ViewerOrigin(
        index: index,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: SizedBox(
          height: height,
          child: ColoredBox(color: Color(0xFF000000 + index * 0x111111)),
        ),
      ),
    ),
  );

  Rect morphRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('mpx-viewer-morph')));

  double morphOpacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find.descendant(
          of: find.byKey(const ValueKey('mpx-viewer-morph')),
          matching: find.byType(Opacity),
        ),
      )
      .opacity;

  Opacity originOpacity(WidgetTester tester, int index) =>
      tester.widget<Opacity>(
        find
            .descendant(
              of: find.byWidgetPredicate(
                (widget) => widget is ViewerOrigin && widget.index == index,
              ),
              matching: find.byType(Opacity),
            )
            .first,
      );

  MediaViewerState viewer(WidgetTester tester) =>
      tester.state<MediaViewerState>(find.byType(MediaViewer));

  Future<void> openedFrom(WidgetTester tester, int index) async {
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is ViewerOrigin && widget.index == index,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> settleOpen(WidgetTester tester) =>
      tester.pump(_policy.openDuration + const Duration(milliseconds: 1));

  /// Closes the viewer and pumps to just before the close transition ends.
  Future<void> nearlyClosed(WidgetTester tester) async {
    viewer(tester).close().ignore();
    await tester.pump();
    await tester.pump(_policy.closeDuration - const Duration(milliseconds: 1));
  }

  void expectRect(Rect actual, Rect expected) {
    for (final (a, e) in [
      (actual.left, expected.left),
      (actual.top, expected.top),
      (actual.right, expected.right),
      (actual.bottom, expected.bottom),
    ]) {
      expect(a, closeTo(e, 2), reason: '$actual vs $expected');
    }
  }

  testWidgets('opens from a grid thumbnail with no bridge of the host', (
    tester,
  ) async {
    await pumpHost(
      tester,
      GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
        ),
        itemCount: 20,
        itemBuilder: (context, index) => thumbnail(index),
      ),
    );

    await openedFrom(tester, 3);

    // Tile 3 is the second row's right one: (200, 200) to (400, 400).
    expectRect(morphRect(tester), const Rect.fromLTWH(200, 200, 200, 200));
    expect(originOpacity(tester, 3).opacity, 0);
    await settleOpen(tester);
    expect(viewer(tester).isOpen, isTrue);

    await nearlyClosed(tester);
    expectRect(morphRect(tester), const Rect.fromLTWH(200, 200, 200, 200));
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewer), findsNothing);
    expect(originOpacity(tester, 3).opacity, 1);
  });

  testWidgets('a thumbnail a list clips opens clipped by the list', (
    tester,
  ) async {
    final list = ScrollController();
    addTearDown(list.dispose);
    await pumpHost(
      tester,
      ListView.builder(
        controller: list,
        itemCount: 20,
        itemBuilder: (context, index) => thumbnail(index, height: 300),
      ),
    );
    list.jumpTo(400);
    await tester.pump();

    final origin = ViewerOriginScope.of(
      tester.element(find.byType(ListView)),
    ).bridgeFor(source).originOf(1)!;
    expect(origin.rect, const Rect.fromLTWH(0, -100, 400, 300));
    expect(origin.clip, const Rect.fromLTWH(0, 0, 400, 800));
    expect(origin.radius, const BorderRadius.all(Radius.circular(8)));

    await openedFrom(tester, 1);
    expectRect(morphRect(tester), const Rect.fromLTWH(0, -100, 400, 300));
  });

  testWidgets('closes back to a thumbnail that scrolled since opening', (
    tester,
  ) async {
    final list = ScrollController();
    addTearDown(list.dispose);
    await pumpHost(
      tester,
      ListView.builder(
        controller: list,
        itemCount: 20,
        itemBuilder: (context, index) => thumbnail(index, height: 300),
      ),
    );
    await openedFrom(tester, 1);
    await settleOpen(tester);

    list.jumpTo(100);
    await tester.pump();
    await nearlyClosed(tester);

    expectRect(morphRect(tester), const Rect.fromLTWH(0, 200, 400, 300));
  });

  testWidgets('an origin that left the screen closes with the fade', (
    tester,
  ) async {
    final list = ScrollController();
    addTearDown(list.dispose);
    await pumpHost(
      tester,
      ListView.builder(
        controller: list,
        itemCount: 20,
        itemBuilder: (context, index) => thumbnail(index, height: 300),
      ),
    );
    await openedFrom(tester, 0);
    await settleOpen(tester);

    list.jumpTo(3000);
    await tester.pump();
    viewer(tester).close().ignore();
    await tester.pump();
    await tester.pump(_policy.closeDuration ~/ 2);

    // No morph back: the picture shrinks in place and fades.
    expect(morphRect(tester).center, viewerSize.center(Offset.zero));
    expect(morphOpacity(tester), lessThan(1));
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewer), findsNothing);
  });

  testWidgets('closing on another item scrolls its thumbnail into view', (
    tester,
  ) async {
    final list = ScrollController();
    addTearDown(list.dispose);
    final controller = ViewerController();
    addTearDown(controller.dispose);
    await pumpHost(
      tester,
      ListView.builder(
        controller: list,
        cacheExtent: 3000,
        itemCount: 20,
        itemBuilder: (context, index) => Builder(
          builder: (context) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => MediaViewer.show(
              context,
              source: source,
              initialIndex: index,
              policy: _policy,
              scope: scope,
              controller: controller,
            ),
            child: ViewerOrigin(
              index: index,
              child: const SizedBox(height: 300),
            ),
          ),
        ),
      ),
    );
    await openedFrom(tester, 0);
    await settleOpen(tester);

    controller.jumpTo(5);
    await tester.pump();
    expect(controller.index, 5);
    controller.close().ignore();
    await tester.pump();
    await tester.pump();

    // Item 5 (1500..1800) is centred: the list scrolled to 1250.
    expect(list.offset, 1250);
    await tester.pump(_policy.closeDuration - const Duration(milliseconds: 1));
    expectRect(morphRect(tester), const Rect.fromLTWH(0, 250, 400, 300));
  });

  testWidgets('a key-registered origin is found through the gallery', (
    tester,
  ) async {
    await pumpHost(
      tester,
      ListView(
        children: [
          ViewerOrigin(media: photoKey(2), child: const SizedBox(height: 90)),
        ],
      ),
    );

    final bridge = ViewerOriginScope.of(
      tester.element(find.byType(ListView)),
    ).bridgeFor(source);
    expect(bridge.originOf(2)!.rect, const Rect.fromLTWH(0, 0, 400, 90));
    expect(bridge.originOf(1), isNull);

    bridge.setHidden(2, hidden: true);
    await tester.pump();
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0);
  });

  testWidgets('a frame handed out stays valid after its origin shows again', (
    tester,
  ) async {
    await pumpHost(tester, ListView(children: [thumbnail(0, height: 90)]));
    final bridge = ViewerOriginScope.of(
      tester.element(find.byType(ListView)),
    ).bridgeFor(source);

    final frame = bridge.frameOf(0)!;
    bridge
      ..setHidden(0, hidden: true)
      ..setHidden(0, hidden: false);

    expect(frame.debugDisposed, isFalse);
    frame.dispose();
  });

  testWidgets('the frame of a thumbnail whose content has nothing to show '
      'is clear: a page it stands in for shows no box', (tester) async {
    await pumpHost(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: ViewerOrigin(
          index: 0,
          child: ContentView(
            content: photoKey(0),
            scope: scope,
            preset: AssetPresets.media(
              size: const Size(120, 90),
              devicePixelRatio: 1,
              profile: const AssetProfile(),
            ),
          ),
        ),
      ),
    );
    final bridge = ViewerOriginScope.of(
      tester.element(find.byType(ViewerOrigin)),
    ).bridgeFor(source);

    final frame = bridge.frameOf(0)!;
    addTearDown(frame.dispose);
    final pixels = await tester.runAsync(frame.toByteData);

    final bytes = pixels!.buffer.asUint8List();
    expect([
      for (var i = 3; i < bytes.length; i += 4) bytes[i],
    ], everyElement(0));
  });

  testWidgets('the frame of a thumbnail is its picture alone: the status '
      'control and the badge over it are not in it', (tester) async {
    scope.dispose();
    scope = AssetCacheScope(
      producer: producer,
      clock: clock,
      autoDownload: FakeAutoDownloadPolicy(),
    );
    await pumpHost(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: ViewerOrigin(
          index: 0,
          child: ContentView(
            content: photoKey(0),
            scope: scope,
            preset: AssetPresets.media(
              size: const Size(120, 90),
              devicePixelRatio: 1,
              profile: const AssetProfile(),
            ),
            status: const MediaStatusMode.control(),
            badge: true,
          ),
        ),
      ),
    );
    producer.last
      ..describe(
        MediaDescriptor(
          key: photoKey(0),
          kind: MediaKind.video,
          duration: const Duration(seconds: 13),
          byteSize: 4718592,
        ),
      )
      ..awaitingUser();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The chrome shows on the thumbnail.
    expect(find.text('0:13'), findsOneWidget);
    expect(find.byType(MediaStatusControl), findsOneWidget);

    final bridge = ViewerOriginScope.of(
      tester.element(find.byType(ViewerOrigin)),
    ).bridgeFor(source);
    final frame = bridge.frameOf(0)!;
    addTearDown(frame.dispose);
    final pixels = await tester.runAsync(frame.toByteData);

    expect((frame.width, frame.height), (120, 90));
    final bytes = pixels!.buffer.asUint8List();
    expect([
      for (var i = 3; i < bytes.length; i += 4) bytes[i],
    ], everyElement(0));
  });

  testWidgets('a picture inset in its thumbnail keeps its place in a frame '
      "of the thumbnail's size", (tester) async {
    await pumpHost(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: ViewerOrigin(
          index: 0,
          child: ColoredBox(
            color: const Color(0xFFFF0000),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: ContentView(
                content: photoKey(0),
                scope: scope,
                preset: AssetPresets.media(
                  size: const Size(100, 70),
                  devicePixelRatio: 1,
                  profile: const AssetProfile(),
                ),
                badge: true,
              ),
            ),
          ),
        ),
      ),
    );
    final bridge = ViewerOriginScope.of(
      tester.element(find.byType(ViewerOrigin)),
    ).bridgeFor(source);

    final frame = bridge.frameOf(0)!;
    addTearDown(frame.dispose);
    final pixels = await tester.runAsync(frame.toByteData);

    expect((frame.width, frame.height), (120, 90));
    final bytes = pixels!.buffer.asUint8List();
    // The host's box around the picture is not the picture.
    expect([
      for (var i = 3; i < bytes.length; i += 4) bytes[i],
    ], everyElement(0));
  });

  group('ViewerController', () {
    testWidgets('observes the item, the open state and the controls', (
      tester,
    ) async {
      final controller = ViewerController();
      addTearDown(controller.dispose);
      var heard = 0;
      controller.addListener(() => heard++);
      tester.view.physicalSize = viewerSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaViewer(
            source: source,
            initialIndex: 0,
            scope: scope,
            controller: controller,
          ),
        ),
      );
      expect(controller.isAttached, isTrue);
      expect(controller.isOpen, isFalse);
      await tester.pump();
      await settleOpen(tester);
      expect(controller.isOpen, isTrue);

      controller.controlsVisible = false;
      expect(viewer(tester).controlsVisible, isFalse);

      controller.jumpTo(4);
      await tester.pump();
      expect(controller.index, 4);
      expect(heard, greaterThanOrEqualTo(4));

      await tester.pumpWidget(const SizedBox());
      expect(controller.isAttached, isFalse);
      expect(controller.index, isNull);
    });
    testWidgets('attaching and detaching never rebuild a listener mid-build', (
      tester,
    ) async {
      final controller = ViewerController();
      addTearDown(controller.dispose);
      tester.view.physicalSize = viewerSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var showViewer = false;
      late StateSetter setHost;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StatefulBuilder(
            builder: (context, setState) {
              setHost = setState;
              return Stack(
                children: [
                  ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) =>
                        Text('attached: ${controller.isAttached}'),
                  ),
                  if (showViewer)
                    MediaViewer(
                      source: source,
                      initialIndex: 0,
                      scope: scope,
                      controller: controller,
                    ),
                ],
              );
            },
          ),
        ),
      );

      setHost(() => showViewer = true);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(find.text('attached: true'), findsOneWidget);

      setHost(() => showViewer = false);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(find.text('attached: false'), findsOneWidget);
    });
  });

  group('embedded pages', () {
    testWidgets('a photo page pages in a host pager until it is zoomed', (
      tester,
    ) async {
      final pages = PageController();
      addTearDown(pages.dispose);
      var zoomed = false;
      tester.view.physicalSize = viewerSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StatefulBuilder(
            builder: (context, setState) => PageView.builder(
              controller: pages,
              physics: zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: 3,
              itemBuilder: (context, index) => ViewerPhotoPage(
                policy: _policy,
                contentSize: fittedRect.size,
                doubleTapZoom: 3,
                onZoomedChanged: (value) => setState(() => zoomed = value),
                child: const ColoredBox(color: Color(0xFF336699)),
              ),
            ),
          ),
        ),
      );

      await tester.drag(find.byType(PageView), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(pages.page, 1);

      await tester.tapAt(const Offset(200, 400));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      final page = tester.state<ViewerPhotoPageState>(
        find.byType(ViewerPhotoPage).at(0),
      );
      expect(page.zoom, 3);
      expect(zoomed, isTrue);

      await tester.drag(find.byType(PageView), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(pages.page, 1);
    });

    testWidgets('a video page plays only while active', (tester) async {
      final backend = FakePlayerBackend(duration: const Duration(minutes: 1));
      final pool = PlayerPool(backend: backend);
      addTearDown(pool.dispose);
      final item = ViewerHarness.videos(1).single;
      tester.view.physicalSize = viewerSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<void> pumpPage({required bool active}) => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ViewerVideoPage(
            item: item,
            players: pool,
            active: active,
            standIn: const Text('still'),
          ),
        ),
      );

      await pumpPage(active: true);
      await tester.pump();
      final page = tester.state<ViewerVideoPageState>(
        find.byType(ViewerVideoPage),
      );
      expect(page.session!.lease.state.value.playing, isTrue);
      expect(find.byType(ViewerVideoControls), findsOneWidget);

      await pumpPage(active: false);
      expect(page.session, isNull);
      expect(find.text('still'), findsOneWidget);
      expect(find.byType(ViewerVideoControls), findsNothing);
    });
  });
}
