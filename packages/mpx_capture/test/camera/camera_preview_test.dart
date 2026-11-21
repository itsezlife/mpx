import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';

void main() {
  Widget preview(CameraSession session) => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(
        width: 120,
        height: 240,
        child: CameraPreview(session: session),
      ),
    ),
  );

  final stub = find.byKey(const ValueKey('mpx-camera-stub'));
  final live = find.byKey(const ValueKey('mpx-camera-live'));

  // Whether a horizontal flip stands between [of] and the preview.
  bool flippedAbove(WidgetTester tester, Finder of) => tester
      .widgetList<Transform>(
        find.ancestor(of: of, matching: find.byType(Transform)),
      )
      .any((t) => t.transform.storage[0] == -1);

  bool liveMirrored(WidgetTester tester) => tester
      .widgetList<Transform>(
        find.descendant(of: live, matching: find.byType(Transform)),
      )
      .any((t) => t.transform.storage[0] == -1);

  double stubOpacity(WidgetTester tester) => tester
      .widgetList<Opacity>(
        find.ancestor(of: stub, matching: find.byType(Opacity)),
      )
      .map((o) => o.opacity)
      .fold(1, (a, b) => a * b);

  Future<(FakeCameraSessions, CameraSession)> open(WidgetTester tester) async {
    final sessions = FakeCameraSessions(textureId: 3, holdsSwitchFrames: true);
    final session = (await tester.runAsync(sessions.open))!;
    await tester.pumpWidget(preview(session));
    expect(stub, findsNothing);
    return (sessions, session);
  }

  for (final twice in [false, true]) {
    testWidgets(
      'a switch ${twice ? 'back to the back camera' : 'to the front camera'} '
      'covers the preview with the last frame as the user saw it, blurred '
      'and never flipped, until the new camera\'s frames, then fades it in '
      '120 ms',
      (tester) async {
        final (sessions, session) = await open(tester);
        if (twice) {
          await tester.runAsync(session.switchCamera);
          sessions.current!.deliverSwitchFrames();
          await tester.pump(const Duration(milliseconds: 600));
          expect(liveMirrored(tester), isTrue);
        }
        await tester.runAsync(session.switchCamera);
        await tester.pump();
        expect(session.value.value.isSwitching, isTrue);
        expect(stub, findsOneWidget);
        expect(flippedAbove(tester, stub), isFalse);
        expect(
          find.ancestor(of: stub, matching: find.byType(ImageFiltered)),
          findsOneWidget,
        );
        expect(stubOpacity(tester), 1);
        await tester.pump(const Duration(milliseconds: 600));
        expect(stubOpacity(tester), 1, reason: 'held until the frames');

        sessions.current!.deliverSwitchFrames();
        await tester.pump();
        expect(liveMirrored(tester), !twice);
        await tester.pump(const Duration(milliseconds: 60));
        expect(stubOpacity(tester), inExclusiveRange(0, 1));
        await tester.pump(const Duration(milliseconds: 70));
        expect(stub, findsNothing);
      },
    );
  }

  testWidgets('a pause covers the preview with the last frame, blurred; a '
      'resume keeps it until the frames come, then the live preview fades in '
      'over 180 ms', (tester) async {
    final (sessions, session) = await open(tester);
    await tester.runAsync(session.pause);
    await tester.pump();
    expect(stub, findsOneWidget);
    expect(
      find.ancestor(of: stub, matching: find.byType(ImageFiltered)),
      findsOneWidget,
    );
    await tester.runAsync(session.resume);
    await tester.pump(const Duration(milliseconds: 500));
    expect(stubOpacity(tester), 1, reason: 'no frames yet');
    sessions.current!.deliverSwitchFrames();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(stubOpacity(tester), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(stub, findsNothing);
  });

  testWidgets('the snapshot is the size the reference samples: 100 px wide '
      'for a switch, 80 for a pause', (tester) async {
    final (sessions, session) = await open(tester);
    await tester.runAsync(session.switchCamera);
    await tester.pump();
    expect(tester.widget<RawImage>(stub).image!.width, 100);
    sessions.current!.deliverSwitchFrames();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(session.pause);
    await tester.pump();
    expect(tester.widget<RawImage>(stub).image!.width, 80);
  });

  testWidgets('a preview under another page does not play a switch made '
      'there, nor when the page closes', (tester) async {
    final sessions = FakeCameraSessions(textureId: 3, holdsSwitchFrames: true);
    final session = await tester.runAsync(sessions.open);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Navigator(
          key: navigator,
          onGenerateRoute: (_) => PageRouteBuilder<void>(
            pageBuilder: (context, _, _) => Center(
              child: SizedBox(
                width: 200,
                height: 300,
                child: CameraPreview(session: session!),
              ),
            ),
          ),
        ),
      ),
    );
    navigator.currentState!
        .push(
          PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (context, _, _) =>
                const ColoredBox(color: Color(0xFF000000)),
          ),
        )
        .ignore();
    await tester.pump();
    await tester.pump();
    await tester.runAsync(session!.switchCamera);
    await tester.pump(const Duration(milliseconds: 200));
    sessions.current!.deliverSwitchFrames();
    await tester.pump(const Duration(seconds: 1));
    navigator.currentState!.pop();
    final turned = <double>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      for (final t in tester.widgetList<Transform>(find.byType(Transform))) {
        // A turn about the vertical axis has a perspective entry.
        if (t.transform.storage[11] != 0) turned.add(t.transform.storage[0]);
      }
    }
    expect(turned, isEmpty, reason: 'no turn plays');
    expect(find.byKey(const ValueKey('mpx-camera-stub')), findsNothing);
  });

  for (final toFront in [true, false]) {
    testWidgets(
      'while the card turns ${toFront ? 'to the front' : 'to the '
                'back'} camera it is the only layer, filling what the preview filled',
      (tester) async {
        final sessions = FakeCameraSessions(
          textureId: 3,
          holdsSwitchFrames: true,
        );
        final session = await tester.runAsync(
          () => sessions.open(
            facing: toFront ? CameraFacing.back : CameraFacing.front,
          ),
        );
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 180,
                height: 390,
                child: CameraPreview(session: session!),
              ),
            ),
          ),
        );
        final box = tester.getRect(find.byType(CameraPreview));
        await tester.runAsync(session.switchCamera);
        await tester.pump();
        final stub = find.byKey(const ValueKey('mpx-camera-stub'));
        for (var ms = 50; ms < 500; ms += 50) {
          await tester.pump(const Duration(milliseconds: 50));
          expect(
            find
                .byType(Texture)
                .evaluate()
                .where(
                  (e) =>
                      e.findAncestorWidgetOfExactType<Offstage>()?.offstage !=
                      true,
                ),
            isEmpty,
            reason: 'no live frames drawn at $ms ms',
          );
          expect(stub, findsOneWidget, reason: 'one card at $ms ms');
          // Untransformed, the card is the preview's own box.
          expect(tester.renderObject<RenderBox>(stub).size, box.size);
        }
        sessions.current!.deliverSwitchFrames();
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          find
              .byType(Texture)
              .evaluate()
              .where(
                (e) =>
                    e.findAncestorWidgetOfExactType<Offstage>()?.offstage !=
                    true,
              ),
          hasLength(1),
          reason: 'the live frames are back',
        );
      },
    );
  }
}
