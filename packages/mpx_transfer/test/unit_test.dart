/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'job/transfer_id_test.dart' as transfer_id_test;
import 'transfers/pause_reasons_test.dart' as pause_reasons_test;
import 'transfers/scheduler_diagnostics_test.dart'
    as scheduler_diagnostics_test;
import 'transfers/transfer_envelope_test.dart' as transfer_envelope_test;
import 'transfers/transfer_verbs_test.dart' as transfer_verbs_test;
import 'transfers/transfer_watch_test.dart' as transfer_watch_test;

void main() {
  group('transfer_id_test', transfer_id_test.main);
  group('pause_reasons_test', pause_reasons_test.main);
  group('scheduler_diagnostics_test', scheduler_diagnostics_test.main);
  group('transfer_envelope_test', transfer_envelope_test.main);
  group('transfer_verbs_test', transfer_verbs_test.main);
  group('transfer_watch_test', transfer_watch_test.main);
}
