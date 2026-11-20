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

  bool mirrored(WidgetTester tester) => tester
      .widgetList<Transform>(
        find.descendant(
          of: find.byType(CameraPreview),
          matching: find.byType(Transform),
        ),
      )
      .any((t) => t.transform.storage[0] == -1);

  bool blurred(WidgetTester tester) =>
      find.byType(ImageFiltered).evaluate().isNotEmpty;

  testWidgets('a switch keeps the old camera\'s frames as they were drawn, '
      'blurred, until the new camera\'s first frame', (tester) async {
    final sessions = FakeCameraSessions(textureId: 3, holdsSwitchFrames: true);
    final session = (await tester.runAsync(sessions.open))!;
    await tester.pumpWidget(preview(session));
    expect(mirrored(tester), isFalse);
    expect(blurred(tester), isFalse);

    await tester.runAsync(session.switchCamera);
    await tester.pump();
    expect(session.value.value.facing, CameraFacing.front);
    expect(session.value.value.isSwitching, isTrue);
    // The texture still holds the back camera's frames: drawn as they were.
    expect(mirrored(tester), isFalse);
    expect(blurred(tester), isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    expect(mirrored(tester), isFalse);
    expect(blurred(tester), isTrue);

    sessions.current!.deliverSwitchFrames();
    await tester.pump();
    expect(session.value.value.isSwitching, isFalse);
    expect(mirrored(tester), isTrue);
    await tester.pump(const Duration(milliseconds: 130));
    expect(blurred(tester), isFalse);
  });

  testWidgets('the preview turns over during the switch', (tester) async {
    final sessions = FakeCameraSessions(textureId: 3, holdsSwitchFrames: true);
    final session = (await tester.runAsync(sessions.open))!;
    await tester.pumpWidget(preview(session));
    await tester.runAsync(session.switchCamera);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final turned = tester
        .widgetList<Transform>(
          find.descendant(
            of: find.byType(CameraPreview),
            matching: find.byType(Transform),
          ),
        )
        .where(
          (t) => t.transform.storage[0] != 1 && t.transform.storage[0] != -1,
        );
    expect(turned, isNotEmpty, reason: 'turned about the vertical axis');
    sessions.current!.deliverSwitchFrames();
    await tester.pump(const Duration(milliseconds: 600));
  });
}
