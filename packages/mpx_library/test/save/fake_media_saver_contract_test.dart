import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

void main() {
  MediaSaverContract.run(() {
    final transfers = FakeTrackedTransfers();
    final saver = FakeMediaSaver(transfers: transfers, progressSteps: 2);
    return MediaSaverHarness(
      saver: saver,
      file: (index) => 'fake/source-$index.jpg',
      denyAccess: () => saver.saveAccess = SaveAccess.denied,
      transfers: transfers,
      withoutTransfers: () => FakeMediaSaver(progressSteps: 2),
    );
  });

  MediaSaverContract.run(() {
    final transfers = FakeTrackedTransfers();
    final saver = FakeMediaSaver(
      transfers: transfers,
      changeBlock: true,
      progressSteps: 2,
    );
    return MediaSaverHarness(
      saver: saver,
      file: (index) => 'fake/source-$index.jpg',
      changeBlock: true,
      transfers: transfers,
      withoutTransfers: () =>
          FakeMediaSaver(changeBlock: true, progressSteps: 2),
      denyAccess: () => saver.saveAccess = SaveAccess.denied,
      failBlock: () => saver.blockFailure = SaveFailure.noSpace,
    );
  });
}
