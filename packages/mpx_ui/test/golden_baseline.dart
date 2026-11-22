import 'dart:ffi' show Abi;
import 'dart:io' show Directory, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// The host every golden baseline belongs to: the CI runner (`ubuntu-latest`,
/// the Flutter that check.yml pins).
///
/// Rasterization differs by host (an arm64 Mac antialiases glyph edges
/// differently from an x64 Linux runner), so a baseline holds only on the
/// host that made it. Regenerate baselines with the Check workflow's
/// `update_goldens` dispatch, never on a Mac.
const String goldenBaselineHost = 'linux_x64';

/// Pins [goldenFileComparator] to a [GoldenBaselineComparator] beside
/// [testFile] (its path from the package root) for the calling file's tests,
/// and restores the previous comparator after them: the files share the
/// process inside unit_test.dart.
void useGoldenBaselines(String testFile) {
  late GoldenFileComparator previous;
  setUpAll(() {
    previous = goldenFileComparator;
    goldenFileComparator = GoldenBaselineComparator(
      Uri.file('${Directory.current.path}/$testFile'),
    );
  });
  tearDownAll(() => goldenFileComparator = previous);
}

/// A [LocalFileComparator] that compares and regenerates only on
/// [goldenBaselineHost].
///
/// On any other host a comparison is reported as skipped, never passed;
/// `GOLDEN_BASELINE=compare` compares anyway, to look at the differences.
/// Regenerating elsewhere fails, so a baseline is never written where it
/// cannot hold.
final class GoldenBaselineComparator extends LocalFileComparator {
  /// Creates a comparator for the goldens next to [testFile].
  GoldenBaselineComparator(super.testFile);

  static final String _host = Abi.current().toString();

  static bool get _onBaselineHost => _host == goldenBaselineHost;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    if (!_onBaselineHost &&
        Platform.environment['GOLDEN_BASELINE'] != 'compare') {
      markTestSkipped(
        'golden ${golden.path} not compared on $_host: baselines are '
        '$goldenBaselineHost',
      );
      return true;
    }
    return super.compare(imageBytes, golden);
  }

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {
    if (!_onBaselineHost) {
      throw FlutterError(
        'golden ${golden.path} not regenerated on $_host: a baseline '
        'written here fails on $goldenBaselineHost. Regenerate with the '
        'Check workflow (update_goldens).',
      );
    }
    return super.update(golden, imageBytes);
  }
}
