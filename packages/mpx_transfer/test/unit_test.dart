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
import 'journal/record_log_test.dart' as record_log_test;
import 'journal/stored_format_test.dart' as stored_format_test;
import 'journal/transfer_journal_test.dart' as transfer_journal_test;
import 'publish/publish_diagnostics_test.dart' as publish_diagnostics_test;
import 'publish/publish_envelope_test.dart' as publish_envelope_test;
import 'publish/publish_job_test.dart' as publish_job_test;
import 'publish/publish_kill_test.dart' as publish_kill_test;
import 'publish/publish_open_test.dart' as publish_open_test;
import 'publish/publish_order_hold_cancel_test.dart'
    as publish_order_hold_cancel_test;
import 'publish/publish_outcome_test.dart' as publish_outcome_test;
import 'publish/publish_page_source_test.dart' as publish_page_source_test;
import 'publish/publish_progress_test.dart' as publish_progress_test;
import 'publish/publish_record_codec_test.dart' as publish_record_codec_test;
import 'publish/publish_tracked_test.dart' as publish_tracked_test;
import 'publish/publish_tracked_view_test.dart' as publish_tracked_view_test;
import 'publish/publish_watch_jobs_test.dart' as publish_watch_jobs_test;
import 'reuse/reuse_facade_test.dart' as reuse_facade_test;
import 'reuse/reuse_table_contract_test.dart' as reuse_table_contract_test;
import 'transfers/android_transfer_envelope_test.dart'
    as android_transfer_envelope_test;
import 'transfers/envelope_interruptions_test.dart'
    as envelope_interruptions_test;
import 'transfers/ios_transfer_envelope_test.dart'
    as ios_transfer_envelope_test;
import 'transfers/journal_diagnostics_test.dart' as journal_diagnostics_test;
import 'transfers/journal_kill_test.dart' as journal_kill_test;
import 'transfers/pause_reasons_test.dart' as pause_reasons_test;
import 'transfers/scheduler_diagnostics_test.dart'
    as scheduler_diagnostics_test;
import 'transfers/system_active_test.dart' as system_active_test;
import 'transfers/transfer_envelope_test.dart' as transfer_envelope_test;
import 'transfers/transfer_verbs_test.dart' as transfer_verbs_test;
import 'transfers/transfer_watch_test.dart' as transfer_watch_test;
import 'transfers/upload_source_copies_test.dart' as upload_source_copies_test;
import 'upload/multipart_upload_transport_test.dart'
    as multipart_upload_transport_test;
import 'upload/numbered_parts_transport_test.dart'
    as numbered_parts_transport_test;
import 'upload/tus_upload_transport_test.dart' as tus_upload_transport_test;
import 'upload/upload_diagnostics_test.dart' as upload_diagnostics_test;
import 'upload/upload_engine_test.dart' as upload_engine_test;
import 'upload/upload_kill_test.dart' as upload_kill_test;
import 'upload/upload_lanes_test.dart' as upload_lanes_test;
import 'upload/upload_resume_test.dart' as upload_resume_test;
import 'upload/upload_transport_contract_test.dart'
    as upload_transport_contract_test;

void main() {
  group(
    'tracked_download_diagnostics_test',
    tracked_download_diagnostics_test.main,
  );
  group('tracked_download_view_test', tracked_download_view_test.main);
  group('tracked_downloads_test', tracked_downloads_test.main);
  group('transfer_id_test', transfer_id_test.main);
  group('journal_store_contract_test', journal_store_contract_test.main);
  group('record_log_test', record_log_test.main);
  group('stored_format_test', stored_format_test.main);
  group('transfer_journal_test', transfer_journal_test.main);
  group('publish_diagnostics_test', publish_diagnostics_test.main);
  group('publish_envelope_test', publish_envelope_test.main);
  group('publish_job_test', publish_job_test.main);
  group('publish_kill_test', publish_kill_test.main);
  group('publish_open_test', publish_open_test.main);
  group('publish_order_hold_cancel_test', publish_order_hold_cancel_test.main);
  group('publish_tracked_test', publish_tracked_test.main);
  group('publish_tracked_view_test', publish_tracked_view_test.main);
  group('publish_outcome_test', publish_outcome_test.main);
  group('publish_page_source_test', publish_page_source_test.main);
  group('publish_progress_test', publish_progress_test.main);
  group('publish_record_codec_test', publish_record_codec_test.main);
  group('publish_watch_jobs_test', publish_watch_jobs_test.main);
  group('reuse_facade_test', reuse_facade_test.main);
  group('reuse_table_contract_test', reuse_table_contract_test.main);
  group('android_transfer_envelope_test', android_transfer_envelope_test.main);
  group('envelope_interruptions_test', envelope_interruptions_test.main);
  group('ios_transfer_envelope_test', ios_transfer_envelope_test.main);
  group('journal_diagnostics_test', journal_diagnostics_test.main);
  group('journal_kill_test', journal_kill_test.main);
  group('pause_reasons_test', pause_reasons_test.main);
  group('scheduler_diagnostics_test', scheduler_diagnostics_test.main);
  group('system_active_test', system_active_test.main);
  group('transfer_envelope_test', transfer_envelope_test.main);
  group('transfer_verbs_test', transfer_verbs_test.main);
  group('transfer_watch_test', transfer_watch_test.main);
  group(
    'multipart_upload_transport_test',
    multipart_upload_transport_test.main,
  );
  group('numbered_parts_transport_test', numbered_parts_transport_test.main);
  group('tus_upload_transport_test', tus_upload_transport_test.main);
  group('upload_diagnostics_test', upload_diagnostics_test.main);
  group('upload_engine_test', upload_engine_test.main);
  group('upload_kill_test', upload_kill_test.main);
  group('upload_lanes_test', upload_lanes_test.main);
  group('upload_resume_test', upload_resume_test.main);
  group('upload_transport_contract_test', upload_transport_contract_test.main);
  group('upload_source_copies_test', upload_source_copies_test.main);
}
