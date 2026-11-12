/// Optional media UI for mpx: a fullscreen media viewer and feed list and
/// pager widgets.
///
/// `FeedListView` plays every visible clip of a list muted, as a list-mode
/// `FeedPolicy` of `mpx_player` says, and preloads the items ahead through
/// the core's asset cache scope.
library;

export 'src/feed/feed_list_view.dart';
