/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'download/tracked_download_diagnostics_test.dart'
    as tracked_download_diagnostics_test;
import 'download/tracked_download_view_test.dart' as tracked_download_view_test;
import 'download/tracked_downloads_test.dart' as tracked_downloads_test;
import 'job/transfer_id_test.dart' as transfer_id_test;
import 'journal/journal_store_contract_test.dart'
    as journal_store_contract_test;
import 'journal/transfer_journal_test.dart' as transfer_journal_test;
import 'transfers/journal_diagnostics_test.dart' as journal_diagnostics_test;
import 'transfers/journal_kill_test.dart' as journal_kill_test;
import 'transfers/pause_reasons_test.dart' as pause_reasons_test;
import 'transfers/scheduler_diagnostics_test.dart'
    as scheduler_diagnostics_test;
import 'transfers/transfer_envelope_test.dart' as transfer_envelope_test;
import 'transfers/transfer_verbs_test.dart' as transfer_verbs_test;
import 'transfers/transfer_watch_test.dart' as transfer_watch_test;

void main() {
  group(
    'tracked_download_diagnostics_test',
    tracked_download_diagnostics_test.main,
  );
  group('tracked_download_view_test', tracked_download_view_test.main);
  group('tracked_downloads_test', tracked_downloads_test.main);
  group('transfer_id_test', transfer_id_test.main);
  group('journal_store_contract_test', journal_store_contract_test.main);
  group('transfer_journal_test', transfer_journal_test.main);
  group('journal_diagnostics_test', journal_diagnostics_test.main);
  group('journal_kill_test', journal_kill_test.main);
  group('pause_reasons_test', pause_reasons_test.main);
  group('scheduler_diagnostics_test', scheduler_diagnostics_test.main);
  group('transfer_envelope_test', transfer_envelope_test.main);
  group('transfer_verbs_test', transfer_verbs_test.main);
  group('transfer_watch_test', transfer_watch_test.main);
}
