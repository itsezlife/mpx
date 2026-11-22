import 'dart:async';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/feature/timeline/data/mastodon_client.dart';
import 'package:mpx_example/social/src/feature/timeline/data/timeline_repository.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_example/social/src/feature/timeline/model/topic.dart';

/// A [TimelineRepository] that answers from what a test queues, and
/// remembers what it was asked for.
final class FakeTimelineRepository implements TimelineRepository {
  /// What each call answers, in order: a [TimelinePage], or a
  /// [MastodonFailure] to throw.
  final List<Object> answers = [];

  /// The cursors the calls came with, in order.
  final List<String?> cursors = [];

  /// When set, a call waits for it before it answers.
  Completer<void>? gate;

  @override
  Future<TimelinePage> page(Topic topic, {String? cursor}) async {
    cursors.add(cursor);
    await gate?.future;
    return switch (answers.removeAt(0)) {
      final TimelinePage page => page,
      final MastodonFailure failure => throw MastodonException(failure, 'fake'),
      final other => throw StateError('Not an answer: $other'),
    };
  }

  /// A post of [mediaCount] photos.
  static Post post(String id, {int mediaCount = 1}) => Post(
    id: PostId(id),
    host: 'm.example',
    author: const Account(
      handle: 'a@m.example',
      displayName: 'A',
      avatar: null,
    ),
    createdAt: DateTime.utc(2026, 11, 22),
    text: PostText.empty,
    media: [
      for (var i = 0; i < mediaCount; i++)
        PostMedia(
          key: MediaKey.external('m.example/media/$id-$i'),
          kind: PostMediaKind.photo,
        ),
    ],
    url: 'https://m.example/@a/$id',
  );
}
