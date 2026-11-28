import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

void main() {
  MediaSaverContract.run(() {
    final saver = FakeMediaSaver(progressSteps: 2);
    return MediaSaverHarness(
      saver: saver,
      file: (index) => 'fake/source-$index.jpg',
      denyAccess: () => saver.saveAccess = SaveAccess.denied,
    );
  });

  MediaSaverContract.run(() {
    final saver = FakeMediaSaver(changeBlock: true, progressSteps: 2);
    return MediaSaverHarness(
      saver: saver,
      file: (index) => 'fake/source-$index.jpg',
      changeBlock: true,
      denyAccess: () => saver.saveAccess = SaveAccess.denied,
      failBlock: () => saver.blockFailure = SaveFailure.noSpace,
    );
  });
}
