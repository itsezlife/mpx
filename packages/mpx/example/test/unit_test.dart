import 'package:flutter_test/flutter_test.dart';

import 'lab/corpus_test.dart' as corpus;
import 'lab/lab_coverage_test.dart' as lab_coverage;
import 'lab/lab_download_test.dart' as lab_download;
import 'lab/lab_net_test.dart' as lab_net;
import 'lab/pointer_tape_test.dart' as pointer_tape;
import 'social/album_layout_test.dart' as album_layout;
import 'social/formatting_test.dart' as formatting;
import 'social/post_selection_test.dart' as post_selection;
import 'social/post_text_view_test.dart' as post_text_view;
import 'social/status_adapter_test.dart' as status_adapter;
import 'social/status_html_test.dart' as status_html;
import 'social/timeline_controller_test.dart' as timeline_controller;
import 'video_through_stack_test.dart' as video_through_stack;

void main() {
  group('corpus', corpus.main);
  group('lab coverage', lab_coverage.main);
  group('lab download', lab_download.main);
  group('lab net', lab_net.main);
  group('pointer tape', pointer_tape.main);
  group('social album layout', album_layout.main);
  group('social formatting', formatting.main);
  group('social post selection', post_selection.main);
  group('social post text view', post_text_view.main);
  group('social status adapter', status_adapter.main);
  group('social status html', status_html.main);
  group('social timeline controller', timeline_controller.main);
  group('video through the stack', video_through_stack.main);
}
