import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  const key = MediaKey.remote('clip');
  late FakePlayerBackend backend;
  late PlayerPool pool;
  late PlayerLease lease;

  setUp(() {
    backend = FakePlayerBackend(duration: const Duration(seconds: 100));
    pool = PlayerPool(backend: backend);
    lease = pool.lease(key)..prepare();
  });
  tearDown(() {
    lease.release();
    pool.dispose();
  });

  group('ViewerSeekController', () {
    late ViewerSeekController seek;
    var interactions = 0;

    setUp(() {
      interactions = 0;
    });

    ViewerSeekController make(WidgetTester tester, {Duration? knownDuration}) {
      seek = ViewerSeekController(
        vsync: tester,
        lease: lease,
        knownDuration: knownDuration,
        onInteraction: () => interactions++,
      );
      addTearDown(seek.dispose);
      return seek;
    }

    testWidgets('a finger previews a position; the seek is made on release', (
      tester,
    ) async {
      await tester.pump();
      make(tester);

      seek.previewAt(25, 100);
      expect(seek.preview, const Duration(seconds: 25));
      expect(seek.isDragging, isTrue);
      expect(seek.shown, const Duration(seconds: 25));
      // Nothing moved yet: a drag costs one seek, not one per touch event.
      expect(backend.latestFor(key)!.position, Duration.zero);

      seek.previewAt(60, 100);
      expect(backend.latestFor(key)!.position, Duration.zero);

      seek.commit();
      expect(backend.latestFor(key)!.position, const Duration(seconds: 60));
      expect(seek.preview, isNull);
      expect(seek.playhead, const Duration(seconds: 60));
    });

    testWidgets('a touch past either end stays on the bar', (tester) async {
      await tester.pump();
      make(tester);

      seek.previewAt(-30, 100);
      expect(seek.preview, Duration.zero);
      seek.previewAt(400, 100);
      expect(seek.preview, const Duration(seconds: 100));
    });

    testWidgets('a bar with no width previews the start', (tester) async {
      await tester.pump();
      make(tester).previewAt(10, 0);

      expect(seek.preview, Duration.zero);
    });

    testWidgets('the length the host knows stands in until the player has '
        'one', (tester) async {
      // Not prepared: the player reports no length yet.
      final fresh = pool.lease(const MediaKey.remote('other'));
      addTearDown(fresh.release);
      final controller = ViewerSeekController(
        vsync: tester,
        lease: fresh,
        knownDuration: const Duration(seconds: 52),
      );
      addTearDown(controller.dispose);

      expect(controller.duration, const Duration(seconds: 52));
      controller.previewAt(50, 100);
      expect(controller.preview, const Duration(seconds: 26));
    });

    testWidgets('a drag taken away ends the preview and seeks nowhere', (
      tester,
    ) async {
      await tester.pump();
      make(tester);

      seek.previewAt(40, 100);
      seek.cancel();

      expect(seek.preview, isNull);
      expect(backend.latestFor(key)!.position, Duration.zero);

      // Nothing to commit after it.
      seek.commit();
      expect(backend.latestFor(key)!.position, Duration.zero);
    });

    testWidgets('every touch and the release are told to the host', (
      tester,
    ) async {
      await tester.pump();
      make(tester);

      seek
        ..previewAt(10, 100)
        ..previewAt(20, 100)
        ..commit();

      expect(interactions, 3);
    });

    testWidgets('listeners hear the preview, not only the playhead', (
      tester,
    ) async {
      await tester.pump();
      make(tester);
      var heard = 0;
      seek.addListener(() => heard++);

      seek.previewAt(10, 100);
      seek.commit();

      expect(heard, greaterThanOrEqualTo(2));
    });

    testWidgets('a new lease drops a preview of the old one', (tester) async {
      await tester.pump();
      make(tester);
      seek.previewAt(10, 100);

      final other = pool.lease(const MediaKey.remote('next'))..prepare();
      addTearDown(other.release);
      seek.lease = other;

      expect(seek.preview, isNull);
      expect(seek.lease, same(other));
    });
  });

  group('ViewerSeekBar', () {
    Future<ViewerSeekController> pumpBar(
      WidgetTester tester, {
      ViewerSeekBarStyle style = ViewerSeekBarStyle.standard,
    }) async {
      await tester.pump();
      final seek = ViewerSeekController(vsync: tester, lease: lease);
      addTearDown(seek.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 200,
              child: ViewerSeekBar(
                controller: seek,
                foreground: const Color(0xFFFFFFFF),
                style: style,
              ),
            ),
          ),
        ),
      );
      return seek;
    }

    testWidgets('a drag across the bar seeks where the finger left', (
      tester,
    ) async {
      final seek = await pumpBar(tester);
      final bar = find.byType(ViewerSeekBar);
      final left = tester.getTopLeft(bar);

      final gesture = await tester.startGesture(left + const Offset(10, 24));
      await gesture.moveTo(left + const Offset(110, 24));
      await tester.pump();
      // 110 px of 200: just over half of 100 s.
      expect(seek.preview, const Duration(seconds: 55));
      await gesture.up();
      await tester.pump();

      expect(backend.latestFor(key)!.position, const Duration(seconds: 55));
      expect(seek.preview, isNull);
    });

    testWidgets('a tap seeks where it lands', (tester) async {
      await pumpBar(tester);
      final bar = find.byType(ViewerSeekBar);

      await tester.tapAt(tester.getTopLeft(bar) + const Offset(150, 24));
      await tester.pump();

      expect(backend.latestFor(key)!.position, const Duration(seconds: 75));
    });

    testWidgets('a touch cancelled before it became a drag seeks nowhere', (
      tester,
    ) async {
      final seek = await pumpBar(tester);
      final left = tester.getTopLeft(find.byType(ViewerSeekBar));

      final gesture = await tester.startGesture(left + const Offset(10, 24));
      // A touch is a press after the arena waits a moment for a drag.
      await tester.pump(const Duration(milliseconds: 150));
      expect(seek.preview, isNotNull);
      await gesture.cancel();
      await tester.pump();

      expect(seek.preview, isNull);
      expect(backend.latestFor(key)!.position, Duration.zero);
    });

    testWidgets('a drag the system takes away lands where it was, as a '
        'release does', (tester) async {
      final seek = await pumpBar(tester);
      final left = tester.getTopLeft(find.byType(ViewerSeekBar));

      final gesture = await tester.startGesture(left + const Offset(10, 24));
      await gesture.moveTo(left + const Offset(110, 24));
      await gesture.cancel();
      await tester.pump();

      expect(seek.preview, isNull);
      expect(backend.latestFor(key)!.position, const Duration(seconds: 55));
    });
  });

  group('ViewerSeekBarStyle', () {
    test('the standard style is the viewer\'s bar', () {
      expect(ViewerSeekBarStyle.standard.track, 4);
      expect(ViewerSeekBarStyle.standard.thumb, 6);
      expect(ViewerSeekBarStyle.standard.thumbWhileDragging, 8);
      expect(ViewerSeekBarStyle.standard.alignment, 0);
    });

    test('styles are equal by value', () {
      expect(
        const ViewerSeekBarStyle(track: 2, alignment: 1),
        const ViewerSeekBarStyle(track: 2, alignment: 1),
      );
      expect(
        const ViewerSeekBarStyle(track: 2),
        isNot(const ViewerSeekBarStyle(track: 3)),
      );
    });
  });
}
