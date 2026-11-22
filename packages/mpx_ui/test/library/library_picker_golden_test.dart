import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_ui/mpx_ui.dart';

import '../golden_baseline.dart';

import 'library_picker_test.dart';

void main() {
  useGoldenBaselines('test/library/library_picker_golden_test.dart');

  for (final (platform, policy) in [
    ('android', LibraryGridPolicy.$Android),
    ('ios', LibraryGridPolicy.$IOS),
  ]) {
    for (final (state, access, assets, allowed) in [
      ('denied', LibraryAccess.denied, 30, true),
      ('restricted', LibraryAccess.restricted, 30, true),
      (
        'banner',
        identical(policy, LibraryGridPolicy.$IOS)
            ? LibraryAccess.limited
            : LibraryAccess.partial,
        12,
        true,
      ),
      ('empty', LibraryAccess.full, 0, true),
      ('not_allowed', LibraryAccess.full, 30, false),
    ]) {
      testWidgets('$state ($platform)', (tester) async {
        final h = PickerHarness(assets: assets, access: access);
        await h.pump(tester, policy: policy, mediaAllowed: allowed);
        await expectLater(
          find.byType(LibraryPicker),
          matchesGoldenFile('goldens/library_picker_${state}_$platform.png'),
        );
      });
    }
  }
}
