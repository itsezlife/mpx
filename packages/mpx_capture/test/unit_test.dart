/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'preset/compression_preset_test.dart' as compression_preset_test;
import 'transcode/fake_transcoder_contract_test.dart'
    as fake_transcoder_contract_test;

void main() {
  group('compression_preset_test', compression_preset_test.main);
  group('fake_transcoder_contract_test', fake_transcoder_contract_test.main);
}
