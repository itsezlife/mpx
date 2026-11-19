import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_capture/testing.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('mpx_camera'));
  tearDown(() => directory.deleteSync(recursive: true));

  for (final cameras in [2, 1]) {
    group('$cameras camera(s)', () {
      CameraSessionContract.run(
        () => CameraSessionHarness(
          sessions: FakeCameraSessions(cameras: cameras),
          outputDirectory: directory.path,
          recordFor: const Duration(milliseconds: 5),
        ),
      );
    });
  }

  test('without access the session opens denied and takes nothing', () async {
    final session = await FakeCameraSessions(allowed: false).open();
    expect(session.value.value.state, CameraSessionState.denied);
    await expectLater(
      session.capturePhoto(outputPath: '${directory.path}/x.jpg'),
      throwsA(isA<CaptureFailed>()),
    );
  });
}
