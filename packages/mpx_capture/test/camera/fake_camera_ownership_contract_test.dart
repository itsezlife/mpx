import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/testing.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('mpx_owner'));
  tearDown(() => directory.deleteSync(recursive: true));

  CameraOwnershipContract.run(() {
    final camera = FakeCamera();
    return CameraOwnershipHarness(
      sessions: FakeCameraSessions(camera: camera),
      recorder: FakeRoundVideoRecorder(camera: camera),
      outputDirectory: directory.path,
    );
  });
}
