/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'identity/media_descriptor_test.dart' as media_descriptor_test;
import 'identity/media_key_test.dart' as media_key_test;

void main() {
  group('media_descriptor_test', media_descriptor_test.main);
  group('media_key_test', media_key_test.main);
}
