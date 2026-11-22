import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

/// Where a topic's posts come from: always a server's open, signed-out API.
sealed class TimelineSource extends Equatable {
  const TimelineSource(this.host);

  /// The Mastodon server asked.
  final String host;

  @override
  List<Object?> get props => [host];
}

/// The posts with media under one hashtag, as [host] federates them.
final class TimelineSource$Tag extends TimelineSource {
  const TimelineSource$Tag(super.host, this.tag);

  final String tag;

  @override
  List<Object?> get props => [host, tag];
}

/// The posts with media written on [host] itself.
final class TimelineSource$Local extends TimelineSource {
  const TimelineSource$Local(super.host);
}

/// What [host] says is trending; text posts included.
final class TimelineSource$Trending extends TimelineSource {
  const TimelineSource$Trending(super.host);
}

/// Which of a source's posts a topic keeps.
enum PostFilter {
  /// All.
  any,

  /// Posts with two or more attachments: albums.
  albums,

  /// Posts with a video.
  videos,
}

/// A feed the reader picks: a source and what it keeps of it.
@immutable
final class Topic extends Equatable {
  const Topic({
    required this.id,
    required this.label,
    required this.source,
    this.filter = PostFilter.any,
  });

  /// A tag's timeline, opened from a post's text.
  factory Topic.tag(String host, String tag) => Topic(
    id: 'tag:$host:$tag',
    label: '#$tag',
    source: TimelineSource$Tag(host, tag),
  );

  /// Stable name; the controllers of the shell are kept by it.
  final String id;

  final String label;
  final TimelineSource source;
  final PostFilter filter;

  /// The topics the home tabs show, in order.
  static const List<Topic> home = [
    Topic(
      id: 'trending',
      label: 'Trending',
      source: TimelineSource$Trending('mastodon.social'),
    ),
    Topic(
      id: 'albums',
      label: 'Albums',
      source: TimelineSource$Local('photog.social'),
      filter: PostFilter.albums,
    ),
    Topic(
      id: 'photography',
      label: 'Photography',
      source: TimelineSource$Tag('mastodon.social', 'photography'),
    ),
    Topic(
      id: 'wildlife',
      label: 'Wildlife',
      source: TimelineSource$Tag('mastodon.social', 'wildlife'),
    ),
    Topic(
      id: 'art',
      label: 'Art',
      source: TimelineSource$Local('mastodon.art'),
    ),
    Topic(
      id: 'gifs',
      label: 'GIFs',
      source: TimelineSource$Tag('mastodon.social', 'gif'),
    ),
  ];

  /// The topic the reels read: videos, with sound. Under a tag of nature
  /// footage, not the generic `video`, which is mostly news.
  static const Topic reels = Topic(
    id: 'reels',
    label: 'Reels',
    source: TimelineSource$Tag('mastodon.social', 'wildlife'),
    filter: PostFilter.videos,
  );

  @override
  List<Object?> get props => [id, label, source, filter];
}

/// A page of a timeline and where the next one starts.
@immutable
final class TimelinePage extends Equatable {
  const TimelinePage({required this.posts, required this.next});

  final List<Post> posts;

  /// Opaque; null when the source has no more.
  final String? next;

  @override
  List<Object?> get props => [posts, next];
}
