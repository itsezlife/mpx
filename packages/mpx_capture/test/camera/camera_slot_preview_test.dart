import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';

const _labels = CaptureSurfaceLabels(
  close: 'Close',
  shutter: 'Shutter',
  switchCamera: 'Switch camera',
  flash: 'Flash',
);

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('mpx_slot'));
  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget slot(CameraSession session, {required bool paused, Key? key}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 120,
            height: 240,
            child: CameraSlotPreview(
              key: key,
              session: session,
              paused: paused,
              deniedBuilder: (_) => const Text('Allow access to camera'),
            ),
          ),
        ),
      );

  testWidgets('caps at 30 fps and follows the pause signal', (tester) async {
    final sessions = FakeCameraSessions(textureId: 3);
    final session = (await tester.runAsync(sessions.open))!;
    await tester.pumpWidget(slot(session, paused: false));
    await settle(tester);
    expect(session.value.value.frameRateCap, 30);
    expect(session.value.value.isPaused, isFalse);
    expect(find.byType(Texture), findsOneWidget);

    await tester.pumpWidget(slot(session, paused: true));
    await settle(tester);
    expect(session.value.value.isPaused, isTrue);

    await tester.pumpWidget(slot(session, paused: false));
    await settle(tester);
    expect(session.value.value.isPaused, isFalse);
  });

  testWidgets('denied shows the pill and tells the host', (tester) async {
    final sessions = FakeCameraSessions(allowed: false);
    final session = (await tester.runAsync(sessions.open))!;
    final told = <CameraSessionState>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CameraSlotPreview(
          session: session,
          paused: false,
          deniedBuilder: (_) => const Text('Allow access to camera'),
          onUnavailable: told.add,
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Allow access to camera'), findsOneWidget);
    expect(told, [CameraSessionState.denied]);
  });

  testWidgets('expanding into the capture surface keeps the session', (
    tester,
  ) async {
    final sessions = FakeCameraSessions(textureId: 3);
    final session = (await tester.runAsync(sessions.open))!;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Navigator(
          onGenerateRoute: (_) => PageRouteBuilder<void>(
            pageBuilder: (context, _, _) => Builder(
              builder: (context) => GestureDetector(
                onTap: () {
                  final box = context.findRenderObject()! as RenderBox;
                  CameraCaptureSurface.show(
                    context,
                    session: session,
                    labels: _labels,
                    outputDirectory: directory.path,
                    onCaptured: (_) {},
                    from: box.localToGlobal(Offset.zero) & box.size,
                  );
                },
                child: slot(session, paused: false),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byType(CameraSlotPreview));
    await tester.pump(const Duration(milliseconds: 175));
    expect(find.byType(CameraCaptureSurface), findsOneWidget);
    await settle(tester);
    expect(session.value.value.frameRateCap, isNull, reason: 'lifted');
    await tester.tap(find.byKey(const ValueKey('mpx-capture-close')));
    await settle(tester);
    expect(find.byType(CameraCaptureSurface), findsNothing);
    expect(sessions.openCount, 1);
    expect(session.value.value.state, CameraSessionState.available);
    expect(session.value.value.frameRateCap, 30, reason: 'restored');
  });
}
