/// Optional media UI for mpx: a fullscreen media viewer and feed list and
/// pager widgets.
///
/// `MediaViewer` pages through a host's `GallerySource`, opening from and
/// closing to each item's place on the host's surface through an
/// `OriginBridge`, with the gestures of a `ViewerPolicy` (`$Android`) and
/// the colours of the host's `ViewerTokens`. `ViewerOrigin`s under a
/// `ViewerOriginScope` are that bridge for thumbnails in any list; a
/// `ViewerController` drives the viewer, and its photo and video pages work
/// alone in a host's own pager.
///
/// `GalleryPager` is the viewer's pager, and any host's: one gesture owner
/// decides once, from the down point, between a pinch, a pan of a zoomed
/// picture, a dismiss drag and a page drag, with a reference's
/// `GalleryPagerPhysics`, tap timings and `GalleryPageTransition`; a zoomed
/// page hands the rest of a pan on to its neighbour at its edge.
///
/// `FeedListView` plays every visible clip of a list muted, as a list-mode
/// `FeedPolicy` of `mpx_player` says, and preloads the items ahead through
/// the core's asset cache scope. `FeedPagerView` plays the page shown with
/// sound and keeps its neighbours' players prepared, as a pager-mode policy
/// says. Both are built on `mpx_player`'s `FeedController` and `FeedSlot`;
/// `FeedClip` draws a slot's media in a host's own scrollable.
///
/// `LibraryGrid` shows a `mpx_library` album: fixed cells, thumbnails
/// through the asset cache, a `PickerSelection` (`OrderedPickerSelection`
/// by default) with numbered checks and swipe select, as a
/// `LibraryGridPolicy` (`$Android`, `$IOS`) says, and a camera slot the host
/// fills.
library;

export 'src/feed/feed_clip.dart';
export 'src/feed/feed_list_view.dart';
export 'src/feed/feed_pager_view.dart';
export 'src/gallery/gallery_gesture_recognizer.dart' show GalleryDragPhase;
export 'src/gallery/gallery_keep_alive.dart';
export 'src/gallery/gallery_page_gestures.dart';
export 'src/gallery/gallery_page_transition.dart';
export 'src/gallery/gallery_pager.dart';
export 'src/gallery/gallery_pager_physics.dart';
export 'src/gallery/gallery_tap_recognizer.dart' show GalleryTapRules;
export 'src/library/edge_auto_scroll.dart';
export 'src/library/library_album_switcher.dart';
export 'src/library/library_grid.dart';
export 'src/library/library_grid_cell.dart';
export 'src/library/library_grid_diagnostics.dart';
export 'src/library/library_grid_layout.dart';
export 'src/library/library_grid_policy.dart';
export 'src/library/library_grid_tokens.dart';
export 'src/library/library_pages.dart';
export 'src/library/library_picker.dart';
export 'src/library/library_player_sources.dart';
export 'src/library/picker_captures.dart';
export 'src/library/picker_selection.dart';
export 'src/library/picker_selection_preview.dart';
export 'src/library/picker_strip_controller.dart';
export 'src/library/picker_viewer.dart';
export 'src/viewer/gallery_source.dart';
export 'src/viewer/media_viewer.dart';
export 'src/viewer/origin_bridge.dart';
export 'src/viewer/viewer_actions.dart';
export 'src/viewer/viewer_chrome_overlay.dart';
export 'src/viewer/viewer_loading.dart'
    show ViewerBufferingSpinner, ViewerPageStatus;
export 'src/viewer/viewer_origin.dart';
export 'src/viewer/viewer_photo_page.dart';
export 'src/viewer/viewer_policy.dart';
export 'src/viewer/viewer_policy_scope.dart';
export 'src/viewer/viewer_tokens.dart';
export 'src/viewer/viewer_video.dart';
export 'src/viewer/viewer_video_page.dart';
export 'src/viewer/viewer_video_session.dart';
