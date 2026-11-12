/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'signals/device_signals_test.dart' as device_signals_test;
import 'signals/fake_device_signals_test.dart' as fake_device_signals_test;

void main() {
  group('device_signals_test', device_signals_test.main);
  group('fake_device_signals_test', fake_device_signals_test.main);
}
