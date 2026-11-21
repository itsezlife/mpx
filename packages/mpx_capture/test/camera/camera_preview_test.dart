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
}
