import 'package:flutter_test/flutter_test.dart';

import 'lab/corpus_test.dart' as corpus;
import 'lab/lab_coverage_test.dart' as lab_coverage;
import 'lab/lab_download_test.dart' as lab_download;
import 'lab/lab_net_test.dart' as lab_net;
import 'lab/pointer_tape_test.dart' as pointer_tape;
import 'video_through_stack_test.dart' as video_through_stack;

void main() {
  group('corpus', corpus.main);
  group('lab coverage', lab_coverage.main);
  group('lab download', lab_download.main);
  group('lab net', lab_net.main);
  group('pointer tape', pointer_tape.main);
  group('video through the stack', video_through_stack.main);
}
