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
import 'library/edge_auto_scroll_test.dart' as edge_auto_scroll_test;
import 'library/library_grid_cell_golden_test.dart'
    as library_grid_cell_golden_test;
import 'library/library_grid_layout_test.dart' as library_grid_layout_test;
import 'library/library_grid_test.dart' as library_grid_test;
import 'library/library_pages_test.dart' as library_pages_test;
import 'library/library_picker_golden_test.dart' as library_picker_golden_test;
import 'library/library_picker_test.dart' as library_picker_test;
import 'library/library_player_sources_test.dart'
    as library_player_sources_test;
import 'library/picker_captures_test.dart' as picker_captures_test;
import 'library/picker_selection_preview_test.dart'
    as picker_selection_preview_test;
import 'library/picker_selection_test.dart' as picker_selection_test;
import 'library/picker_strip_controller_test.dart'
    as picker_strip_controller_test;
import 'library/picker_viewer_test.dart' as picker_viewer_test;
import 'viewer/media_viewer_test.dart' as media_viewer_test;
import 'viewer/origin_bridge_contract_test.dart' as origin_bridge_contract_test;
import 'viewer/viewer_animated_text_test.dart' as viewer_animated_text_test;
import 'viewer/viewer_backdrop_test.dart' as viewer_backdrop_test;
import 'viewer/viewer_change_test.dart' as viewer_change_test;
import 'viewer/viewer_chrome_test.dart' as viewer_chrome_test;
import 'viewer/viewer_desktop_input_test.dart' as viewer_desktop_input_test;
import 'viewer/viewer_desktop_policy_test.dart' as viewer_desktop_policy_test;
import 'viewer/viewer_gestures_test.dart' as viewer_gestures_test;
import 'viewer/viewer_ios_policy_test.dart' as viewer_ios_policy_test;
import 'viewer/viewer_loading_test.dart' as viewer_loading_test;
import 'viewer/viewer_origin_test.dart' as viewer_origin_test;
import 'viewer/viewer_policy_scope_test.dart' as viewer_policy_scope_test;
import 'viewer/viewer_seek_test.dart' as viewer_seek_test;
import 'viewer/viewer_strip_layout_test.dart' as viewer_strip_layout_test;
import 'viewer/viewer_strip_test.dart' as viewer_strip_test;
import 'viewer/viewer_taps_test.dart' as viewer_taps_test;
import 'viewer/viewer_text_diff_test.dart' as viewer_text_diff_test;
import 'viewer/viewer_video_test.dart' as viewer_video_test;
import 'web_compile_test.dart' as web_compile_test;

void main() {
  group('feed_clip_test', feed_clip_test.main);
  group('feed_list_view_test', feed_list_view_test.main);
  group('feed_pager_view_test', feed_pager_view_test.main);
  group('gallery_pager_test', gallery_pager_test.main);
  group('gallery_physics_test', gallery_physics_test.main);
  group('library_grid_cell_golden_test', library_grid_cell_golden_test.main);
  group('library_grid_layout_test', library_grid_layout_test.main);
  group('library_grid_test', library_grid_test.main);
  group('library_pages_test', library_pages_test.main);
  group('library_picker_golden_test', library_picker_golden_test.main);
  group('library_player_sources_test', library_player_sources_test.main);
  group('library_picker_test', library_picker_test.main);
  group('picker_selection_preview_test', picker_selection_preview_test.main);
  group('picker_selection_test', picker_selection_test.main);
  group('picker_captures_test', picker_captures_test.main);
  group('edge_auto_scroll_test', edge_auto_scroll_test.main);
  group('picker_strip_controller_test', picker_strip_controller_test.main);
  group('picker_viewer_test', picker_viewer_test.main);
  group('media_viewer_test', media_viewer_test.main);
  group('origin_bridge_contract_test', origin_bridge_contract_test.main);
  group('viewer_animated_text_test', viewer_animated_text_test.main);
  group('viewer_backdrop_test', viewer_backdrop_test.main);
  group('viewer_change_test', viewer_change_test.main);
  group('viewer_chrome_test', viewer_chrome_test.main);
  group('viewer_desktop_input_test', viewer_desktop_input_test.main);
  group('viewer_desktop_policy_test', viewer_desktop_policy_test.main);
  group('viewer_gestures_test', viewer_gestures_test.main);
  group('viewer_ios_policy_test', viewer_ios_policy_test.main);
  group('viewer_loading_test', viewer_loading_test.main);
  group('viewer_origin_test', viewer_origin_test.main);
  group('viewer_policy_scope_test', viewer_policy_scope_test.main);
  group('viewer_seek_test', viewer_seek_test.main);
  group('viewer_strip_layout_test', viewer_strip_layout_test.main);
  group('viewer_strip_test', viewer_strip_test.main);
  group('viewer_taps_test', viewer_taps_test.main);
  group('viewer_text_diff_test', viewer_text_diff_test.main);
  group('viewer_video_test', viewer_video_test.main);
  group('web_compile_test', web_compile_test.main);
}
