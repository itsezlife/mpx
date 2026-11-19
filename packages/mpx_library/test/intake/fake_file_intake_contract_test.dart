import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

IntakeFile _file(String name, int size) => IntakeFile(
  source: IntakeSource.path('/tmp/$name'),
  name: name,
  size: size,
  mimeType: 'image/png',
  modified: DateTime.utc(2026, 11, 20),
);

void main() {
  for (final camera in [true, false]) {
    group(camera ? 'with a system camera' : 'without a system camera', () {
      FileIntakeContract.run(() {
        final intake = FakeFileIntake(canCaptureWithSystemCamera: camera);
        return FileIntakeHarness(
          intake: intake,
          arrangeTwoFiles: () async =>
              intake.enqueuePick([_file('a.png', 10), _file('b.png', 20)]),
          arrangeDismissal: () async {},
        );
      });
    });
  }

  test('the fake records what was asked', () async {
    final intake = FakeFileIntake()..enqueueCapture(_file('shot.jpg', 5));
    await intake.pickFiles(filter: IntakeFilter.videos, multiple: false);
    final shot = await intake.captureWithSystemCamera(IntakeCaptureKind.video);
    expect(shot?.name, 'shot.jpg');
    expect(intake.pickRequests.single.filter, IntakeFilter.videos);
    expect(intake.pickRequests.single.multiple, isFalse);
    expect(intake.captureRequests, [IntakeCaptureKind.video]);
  });

  test('the dedup key is name, size and modification time', () {
    expect(_file('a.png', 10).dedupKey, _file('a.png', 10).dedupKey);
    expect(_file('a.png', 10).dedupKey, isNot(_file('a.png', 11).dedupKey));
    const blob = IntakeFile(
      source: IntakeSource.blob(Object()),
      name: 'a.png',
      size: 10,
    );
    expect(blob.dedupKey, isNot(_file('a.png', 10).dedupKey));
  });
}
