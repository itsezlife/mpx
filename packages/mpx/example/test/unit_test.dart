import 'package:flutter_test/flutter_test.dart';

import 'journal/diagnostics_journal_test.dart' as diagnostics_journal;
import 'journal/journal_line_fixture_test.dart' as journal_line_fixture;
import 'journal/journal_page_test.dart' as journal_page;
import 'lab/corpus_test.dart' as corpus;
import 'lab/lab_coverage_test.dart' as lab_coverage;
import 'lab/lab_download_test.dart' as lab_download;
import 'lab/lab_net_test.dart' as lab_net;
import 'lab/pointer_tape_test.dart' as pointer_tape;
import 'social/album_layout_test.dart' as album_layout;
import 'social/aloud_picture_test.dart' as aloud_picture;
import 'social/download_request_test.dart' as download_request;
import 'social/formatting_test.dart' as formatting;
import 'social/inline_sound_test.dart' as inline_sound;
import 'social/post_media_facts_test.dart' as post_media_facts;
import 'social/post_selection_test.dart' as post_selection;
import 'social/post_text_view_test.dart' as post_text_view;
import 'social/sound_requests_test.dart' as sound_requests;
import 'social/status_adapter_test.dart' as status_adapter;
import 'social/status_html_test.dart' as status_html;
import 'social/timeline_controller_test.dart' as timeline_controller;
import 'social/volume_rise_test.dart' as volume_rise;
import 'transfers/dev_upload_server_test.dart' as dev_upload_server;
import 'transfers/transfer_settings_fixture_test.dart'
    as transfer_settings_fixture;
import 'transfers/transfers_page_test.dart' as transfers_page;
import 'transfers/transfers_root_test.dart' as transfers_root;
import 'video_through_stack_test.dart' as video_through_stack;

void main() {
  group('diagnostics journal', diagnostics_journal.main);
  group('journal line fixture', journal_line_fixture.main);
  group('journal page', journal_page.main);
  group('corpus', corpus.main);
  group('lab coverage', lab_coverage.main);
  group('lab download', lab_download.main);
  group('lab net', lab_net.main);
  group('pointer tape', pointer_tape.main);
  group('social album layout', album_layout.main);
  group('social download request', download_request.main);
  group('social formatting', formatting.main);
  group('social aloud picture', aloud_picture.main);
  group('social inline sound', inline_sound.main);
  group('social post media facts', post_media_facts.main);
  group('social post selection', post_selection.main);
  group('social post text view', post_text_view.main);
  group('social sound requests', sound_requests.main);
  group('social status adapter', status_adapter.main);
  group('social volume rise', volume_rise.main);
  group('social status html', status_html.main);
  group('social timeline controller', timeline_controller.main);
  group('transfers dev upload server', dev_upload_server.main);
  group('transfer settings fixture', transfer_settings_fixture.main);
  group('transfers page', transfers_page.main);
  group('transfers root', transfers_root.main);
  group('video through the stack', video_through_stack.main);
}
