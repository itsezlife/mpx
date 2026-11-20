import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_ui/mpx_ui.dart';

import 'library_picker_test.dart';

void main() {
  // The baselines sit beside this file, whether it runs alone or inside
  // unit_test.dart; the previous comparator comes back after.
  late GoldenFileComparator previous;
  setUpAll(() {
    previous = goldenFileComparator;
    goldenFileComparator = LocalFileComparator(
      Uri.file(
        '${Directory.current.path}/test/library/'
        'library_picker_golden_test.dart',
      ),
    );
  });
  tearDownAll(() => goldenFileComparator = previous);

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
