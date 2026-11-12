/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:test/test.dart';

void main() {
  // The stub has no behaviour yet; this keeps the entrypoint runnable until
  // the first real test file replaces it.
  test('package stub loads', () {});
}
