/// Optional media UI for mpx: a fullscreen media viewer and feed list and
/// pager widgets.
///
/// `MediaViewer` pages through a host's `GallerySource`, opening from and
/// closing to each item's place on the host's surface through an
/// `OriginBridge`, with the gestures of a `ViewerPolicy` (`$Android`) and
/// the colours of the host's `ViewerTokens`.
///
/// `FeedListView` plays every visible clip of a list muted, as a list-mode
/// `FeedPolicy` of `mpx_player` says, and preloads the items ahead through
/// the core's asset cache scope. `FeedPagerView` plays the page shown with
/// sound and keeps its neighbours' players prepared, as a pager-mode policy
/// says.
library;

export 'src/feed/feed_clip.dart';
export 'src/feed/feed_list_view.dart';
export 'src/feed/feed_pager_view.dart';
export 'src/viewer/gallery_source.dart';
export 'src/viewer/media_viewer.dart';
export 'src/viewer/origin_bridge.dart';
export 'src/viewer/viewer_actions.dart';
export 'src/viewer/viewer_chrome_overlay.dart';
export 'src/viewer/viewer_photo_page.dart';
export 'src/viewer/viewer_policy.dart';
export 'src/viewer/viewer_tokens.dart';
export 'src/viewer/viewer_video.dart';
