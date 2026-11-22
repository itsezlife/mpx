import 'package:mpx_example/social/src/common/media/media_origins.dart';
import 'package:mpx_example/social/src/feature/timeline/data/dto/mastodon_dto.dart';
import 'package:mpx_example/social/src/feature/timeline/data/mastodon_client.dart';
import 'package:mpx_example/social/src/feature/timeline/data/status_adapter.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_example/social/src/feature/timeline/model/topic.dart';

/// Where a topic's posts are read from: the contract the timeline's
/// controller depends on.
abstract interface class TimelineRepository {
  /// The page of [topic] that starts at [cursor] (the first when null).
  ///
  /// Throws a [MastodonException] when the source cannot be read.
  Future<TimelinePage> page(Topic topic, {String? cursor});
}

/// A [TimelineRepository] over a Mastodon server's open API.
///
/// A source with no filter for what a topic keeps (albums, videos) is read
/// page by page until a page keeps something, so the reader is not shown an
/// empty page with more behind it.
final class MastodonTimelineRepository implements TimelineRepository {
  MastodonTimelineRepository({
    required MastodonClient client,
    required MediaOrigins origins,
    StatusAdapter adapter = const StatusAdapter(),
  }) : _client = client,
       _origins = origins,
       _adapter = adapter;

  final MastodonClient _client;
  final MediaOrigins _origins;
  final StatusAdapter _adapter;

  static const int _limit = 40;

  /// How many raw pages one call reads to find posts a filter keeps.
  static const int _maxReads = 4;

  @override
  Future<TimelinePage> page(Topic topic, {String? cursor}) async {
    var next = cursor;
    final seen = <PostId>{};
    final kept = <Post>[];
    for (var read = 0; read < _maxReads; read++) {
      final statuses = await _read(topic.source, next);
      if (statuses.isEmpty) return TimelinePage(posts: kept, next: null);
      next = _cursorAfter(topic.source, next, statuses);
      for (final status in statuses) {
        final adapted = _adapter.fromStatus(status, host: topic.source.host);
        if (!_keeps(topic, adapted.post) || !seen.add(adapted.post.id)) {
          continue;
        }
        adapted.origins.forEach(_origins.know);
        kept.add(adapted.post);
      }
      if (kept.isNotEmpty) break;
    }
    return TimelinePage(posts: kept, next: next);
  }

  // Every topic but the trending one reads only posts with media; the filter
  // keeps what the topic is about on top of that.
  static bool _keeps(Topic topic, Post post) => switch (topic.filter) {
    PostFilter.any =>
      topic.source is TimelineSource$Trending || post.media.isNotEmpty,
    PostFilter.albums => post.media.length > 1,
    PostFilter.videos => post.media.any(
      (media) => media.kind == PostMediaKind.video,
    ),
  };

  Future<List<StatusDto>> _read(TimelineSource source, String? cursor) =>
      switch (source) {
        TimelineSource$Tag(:final host, :final tag) => _client.statuses(
          host,
          '/api/v1/timelines/tag/$tag',
          {'only_media': true, 'limit': _limit, 'max_id': ?cursor},
        ),
        TimelineSource$Local(:final host) => _client.statuses(
          host,
          '/api/v1/timelines/public',
          {
            'local': true,
            'only_media': true,
            'limit': _limit,
            'max_id': ?cursor,
          },
        ),
        // The trending list pages by offset, not by id.
        TimelineSource$Trending(:final host) => _client.statuses(
          host,
          '/api/v1/trends/statuses',
          {'limit': _limit, 'offset': cursor ?? '0'},
        ),
      };

  static String? _cursorAfter(
    TimelineSource source,
    String? cursor,
    List<StatusDto> statuses,
  ) => switch (source) {
    TimelineSource$Trending() =>
      '${(int.tryParse(cursor ?? '0') ?? 0) + statuses.length}',
    _ => statuses.last.id,
  };
}
