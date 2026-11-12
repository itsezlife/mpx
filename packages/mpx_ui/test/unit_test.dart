/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'feed/feed_list_view_test.dart' as feed_list_view_test;
import 'viewer/media_viewer_test.dart' as media_viewer_test;

void main() {
  group('feed_list_view_test', feed_list_view_test.main);
  group('media_viewer_test', media_viewer_test.main);
}
