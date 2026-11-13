import 'package:flutter_test/flutter_test.dart';

import 'lab/corpus_test.dart' as corpus;
import 'lab/lab_net_test.dart' as lab_net;
import 'lab/pointer_tape_test.dart' as pointer_tape;

void main() {
  group('corpus', corpus.main);
  group('lab net', lab_net.main);
  group('pointer tape', pointer_tape.main);
}
