/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'feed/feed_clip_test.dart' as feed_clip_test;
import 'feed/feed_list_view_test.dart' as feed_list_view_test;
import 'feed/feed_pager_view_test.dart' as feed_pager_view_test;
import 'gallery/gallery_pager_test.dart' as gallery_pager_test;
import 'gallery/gallery_physics_test.dart' as gallery_physics_test;
import 'viewer/media_viewer_test.dart' as media_viewer_test;
import 'viewer/origin_bridge_contract_test.dart' as origin_bridge_contract_test;
import 'viewer/viewer_chrome_test.dart' as viewer_chrome_test;
import 'viewer/viewer_desktop_policy_test.dart' as viewer_desktop_policy_test;
import 'viewer/viewer_ios_policy_test.dart' as viewer_ios_policy_test;
import 'viewer/viewer_loading_test.dart' as viewer_loading_test;
import 'viewer/viewer_origin_test.dart' as viewer_origin_test;
import 'viewer/viewer_policy_scope_test.dart' as viewer_policy_scope_test;
import 'viewer/viewer_video_test.dart' as viewer_video_test;

void main() {
  group('feed_clip_test', feed_clip_test.main);
  group('feed_list_view_test', feed_list_view_test.main);
  group('feed_pager_view_test', feed_pager_view_test.main);
  group('gallery_pager_test', gallery_pager_test.main);
  group('gallery_physics_test', gallery_physics_test.main);
  group('media_viewer_test', media_viewer_test.main);
  group('origin_bridge_contract_test', origin_bridge_contract_test.main);
  group('viewer_chrome_test', viewer_chrome_test.main);
  group('viewer_desktop_policy_test', viewer_desktop_policy_test.main);
  group('viewer_ios_policy_test', viewer_ios_policy_test.main);
  group('viewer_loading_test', viewer_loading_test.main);
  group('viewer_origin_test', viewer_origin_test.main);
  group('viewer_policy_scope_test', viewer_policy_scope_test.main);
  group('viewer_video_test', viewer_video_test.main);
}
