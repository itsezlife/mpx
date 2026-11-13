import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_player/src/backend/picture_in_picture.dart';

/// The contract every [PictureInPicture] meets before anything is shown:
/// no window at first, and closing one that is not up is allowed. Starting
/// one needs an engine of the same backend; the backend's own test covers
/// that.
abstract final class PictureInPictureContract {
  /// Runs it as a test group. [create] builds the picture in picture under
  /// test for each test.
  static void run(PictureInPicture Function() create) {
    group('PictureInPicture contract', () {
      late PictureInPicture pip;

      setUp(() => pip = create());

      test('nothing is shown at first', () {
        expect(pip.active.value, isNull);
      });

      test('closing with nothing up is allowed and changes nothing', () {
        var heard = 0;
        void count() => heard++;
        pip.active.addListener(count);
        addTearDown(() => pip.active.removeListener(count));

        pip
          ..stop()
          ..stop();

        expect(pip.active.value, isNull);
        expect(heard, 0);
      });
    });
  }
}
