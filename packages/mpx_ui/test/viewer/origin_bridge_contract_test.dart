import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_ui/testing.dart';

import 'viewer_harness.dart';

void main() {
  FakeGallerySource gallery() {
    final source = FakeGallerySource([
      for (var i = 0; i < 3; i++) GalleryItem(photoKey(i)),
    ]);
    addTearDown(source.dispose);
    return source;
  }

  // A scope over a list: index 0 registered by index, 1 by media key; 2 has
  // no origin.
  Future<ViewerOriginScopeState> pumpScope(
    WidgetTester tester, {
    GallerySource? source,
  }) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ViewerOriginScope(
          source: source,
          child: ListView(
            children: [
              const ViewerOrigin(
                index: 0,
                child: SizedBox(
                  height: 90,
                  child: ColoredBox(color: Color(0xFF336699)),
                ),
              ),
              ViewerOrigin(
                media: photoKey(1),
                child: const SizedBox(
                  height: 90,
                  child: ColoredBox(color: Color(0xFF993366)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.state<ViewerOriginScopeState>(find.byType(ViewerOriginScope));
  }

  group('ViewerOriginScope', () {
    OriginBridgeContract.run((tester) async {
      final scope = await pumpScope(tester, source: gallery());
      return OriginBridgeHarness(bridge: scope, shown: 0, missing: 2);
    });
  });

  group('ViewerOriginScope.bridgeFor, by media key', () {
    OriginBridgeContract.run((tester) async {
      final source = gallery();
      final scope = await pumpScope(tester);
      return OriginBridgeHarness(
        bridge: scope.bridgeFor(source),
        shown: 1,
        missing: 2,
      );
    });
  });

  group('FakeOriginBridge', () {
    OriginBridgeContract.run((tester) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawPaint(Paint());
      final picture = recorder.endRecording();
      final frame = picture.toImageSync(4, 3);
      picture.dispose();
      addTearDown(frame.dispose);
      final bridge = FakeOriginBridge({
        0: const GalleryOrigin(rect: Rect.fromLTWH(0, 0, 40, 30)),
      });
      bridge.frames[0] = frame;
      return OriginBridgeHarness(bridge: bridge, shown: 0, missing: 2);
    });
  });
}
