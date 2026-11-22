/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'compile/svg_compiler_test.dart' as svg_compiler_test;
import 'decoder/svg_decoder_test.dart' as svg_decoder_test;
import 'decoder/svg_pipeline_test.dart' as svg_pipeline_test;
import 'policy/svg_sanitizer_test.dart' as svg_sanitizer_test;

void main() {
  group('svg_compiler_test', svg_compiler_test.main);
  group('svg_decoder_test', svg_decoder_test.main);
  group('svg_pipeline_test', svg_pipeline_test.main);
  group('svg_sanitizer_test', svg_sanitizer_test.main);
}
