import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_ui/src/viewer/origin_bridge.dart';

/// What an [OriginBridge] contract run needs: a bridge over a surface that
/// shows an origin with a picture at [shown] and none at [missing].
final class OriginBridgeHarness {
  /// Creates a harness.
  const OriginBridgeHarness({
    required this.bridge,
    required this.shown,
    required this.missing,
  });

  /// The bridge under test.
  final OriginBridge bridge;

  /// An index whose origin is on screen and has a picture.
  final int shown;

  /// An index with no origin.
  final int missing;
}

/// The contract every [OriginBridge] meets; see its documentation.
abstract final class OriginBridgeContract {
  /// Runs it as a test group. [create] pumps the surface and builds a fresh
  /// harness for each test; it may register tear-downs.
  static void run(
    Future<OriginBridgeHarness> Function(WidgetTester tester) create,
  ) {
    group('OriginBridge contract', () {
      testWidgets('an item without an origin has no place and no picture', (
        tester,
      ) async {
        final harness = await create(tester);
        expect(harness.bridge.originOf(harness.missing), isNull);
        expect(harness.bridge.frameOf(harness.missing), isNull);
      });

      testWidgets('an origin on screen has a place', (tester) async {
        final harness = await create(tester);
        final origin = harness.bridge.originOf(harness.shown);
        expect(origin, isNotNull);
        expect(origin!.rect.isEmpty, isFalse);
      });

      testWidgets('each picture handed out is the caller’s own', (
        tester,
      ) async {
        final harness = await create(tester);
        final first = harness.bridge.frameOf(harness.shown)!;
        final second = harness.bridge.frameOf(harness.shown)!;
        expect(identical(first, second), isFalse);

        first.dispose();
        expect(second.debugDisposed, isFalse);
        _disposeAll([second, harness.bridge.frameOf(harness.shown)]);
      });

      testWidgets('a hidden origin keeps its place and its picture', (
        tester,
      ) async {
        final harness = await create(tester);
        final bridge = harness.bridge..setHidden(harness.shown, hidden: true);
        await tester.pump();

        expect(bridge.originOf(harness.shown), isNotNull);
        final hidden = bridge.frameOf(harness.shown);
        expect(hidden, isNotNull);

        bridge.setHidden(harness.shown, hidden: false);
        await tester.pump();
        expect(hidden!.debugDisposed, isFalse);
        _disposeAll([hidden]);
      });

      testWidgets('hiding and showing twice is the same as once', (
        tester,
      ) async {
        final harness = await create(tester);
        harness.bridge
          ..setHidden(harness.shown, hidden: true)
          ..setHidden(harness.shown, hidden: true)
          ..setHidden(harness.shown, hidden: false)
          ..setHidden(harness.shown, hidden: false);
        await tester.pump();
        _disposeAll([harness.bridge.frameOf(harness.shown)]);
      });

      testWidgets('reveal completes, with or without an origin', (
        tester,
      ) async {
        final harness = await create(tester);
        for (final index in [harness.shown, harness.missing]) {
          var done = false;
          harness.bridge.reveal(index).then((_) => done = true).ignore();
          await tester.pump();
          await tester.pump();
          expect(done, isTrue, reason: 'reveal($index)');
        }
      });

      testWidgets('a hand-back without an origin is ignored', (tester) async {
        final harness = await create(tester);
        harness.bridge
          ..handBack(harness.missing, const Duration(seconds: 1))
          ..handBack(harness.shown, const Duration(seconds: 1));
      });
    });
  }
}

void _disposeAll(Iterable<ui.Image?> frames) {
  for (final frame in frames) {
    frame?.dispose();
  }
}
