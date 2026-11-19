import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

void main() {
  MediaLibraryContract.run(
    () => MediaLibraryHarness(
      library: FakeMediaLibrary(
        assets: 25,
        access: LibraryAccess.notDetermined,
      ),
      minimumAssets: 25,
    ),
  );
}
