import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/feature/timeline/data/dto/mastodon_dto.dart';
import 'package:mpx_example/social/src/feature/timeline/data/status_adapter.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

StatusDto _status({
  String id = '1',
  List<Map<String, Object?>> media = const [],
  Map<String, Object?>? reblog,
  bool sensitive = false,
  String spoiler = '',
}) => StatusDto.fromJson({
  'id': id,
  'created_at': '2026-11-22T20:47:42.409Z',
  'content': '<p>hello</p>',
  'url': 'https://m.example/@a/$id',
  'sensitive': sensitive,
  'spoiler_text': spoiler,
  'reblog': reblog,
  'replies_count': 2,
  'reblogs_count': 3,
  'favourites_count': 1500,
  'account': {
    'id': '7',
    'acct': 'ann',
    'username': 'ann',
    'display_name': '',
    'avatar': 'https://files.example/avatars/7/abc123.png',
  },
  'media_attachments': media,
});

void main() {
  const adapter = StatusAdapter();

  test('maps the author, the counts and the text', () {
    final (:post, :origins) = adapter.fromStatus(_status(), host: 'm.example');
    expect(post.id, '1');
    expect(post.author.handle, 'ann@m.example');
    // No display name: the account's own name stands in.
    expect(post.author.displayName, 'ann');
    expect(
      post.author.avatar,
      const MediaKey.external('m.example/avatar/7/abc123.png'),
    );
    expect(post.text.plain, 'hello');
    expect((post.replies, post.boosts, post.likes), (2, 3, 1500));
    expect(origins.keys, contains(post.author.avatar));
  });

  test(
    'media are keyed by server and id, never by URL; unsupported ones go',
    () {
      final (:post, :origins) = adapter.fromStatus(
        _status(
          media: [
            {
              'id': '10',
              'type': 'image',
              'url': 'https://files.example/a.jpg',
              'preview_url': 'https://files.example/a_small.jpg',
              'description': 'a cat',
              'meta': {
                'original': {'width': 800, 'height': 600},
              },
            },
            {
              'id': '11',
              'type': 'video',
              'url': 'https://files.example/b.webm',
              'meta': {
                'original': {
                  'width': 640,
                  'height': 360,
                  'duration': 10.0,
                  'bitrate': 800000,
                },
              },
            },
            {'id': '12', 'type': 'gifv', 'url': 'https://files.example/c.mp4'},
            {'id': '13', 'type': 'audio', 'url': 'https://files.example/d.mp3'},
            {'id': '14', 'type': 'hologram', 'url': 'https://files.example/e'},
          ],
        ),
        host: 'm.example',
      );
      expect(post.media.map((m) => m.kind), [
        PostMediaKind.photo,
        PostMediaKind.video,
        PostMediaKind.gif,
      ]);
      final photo = post.media.first;
      expect(photo.key, const MediaKey.external('m.example/media/10'));
      expect(photo.alt, 'a cat');
      expect(photo.aspect, closeTo(4 / 3, 1e-9));
      expect(photo.byteSize, isNull);
      expect(
        origins[photo.key]!.preview,
        Uri.parse('https://files.example/a_small.jpg'),
      );

      final video = post.media[1];
      // A clip weighs about its bitrate for its length.
      expect(video.byteSize, 1000000);
      expect(video.duration, const Duration(seconds: 10));
      expect(origins[video.key]!.mimeType, 'video/webm');
      expect(post.media[2].aspect, 1);
    },
  );

  test('a boost shows the boosted post and names the booster', () {
    final (:post, origins: _) = adapter.fromStatus(
      _status(
        id: '2',
        reblog: {
          'id': '1',
          'created_at': '2026-11-20T00:00:00.000Z',
          'content': '<p>original</p>',
          'account': {'id': '9', 'acct': 'bob@other.example'},
          'media_attachments': <Object?>[],
        },
      ),
      host: 'm.example',
    );
    expect(post.id, '1');
    expect(post.text.plain, 'original');
    expect(post.author.handle, 'bob@other.example');
    expect(post.boostedBy?.handle, 'ann@m.example');
  });

  test('a content warning or sensitive media cover the post', () {
    PostMedia photo() => const PostMedia(
      key: MediaKey.external('m.example/media/1'),
      kind: PostMediaKind.photo,
    );
    final (:post, origins: _) = adapter.fromStatus(
      _status(spoiler: 'spoilers'),
      host: 'm.example',
    );
    expect(post.covered, isTrue);
    // Sensitive with nothing to cover is not covered.
    final sensitive = adapter
        .fromStatus(_status(sensitive: true), host: 'm.example')
        .post;
    expect(sensitive.covered, isFalse);
    expect(
      Post(
        id: const PostId('1'),
        host: 'h',
        author: sensitive.author,
        createdAt: sensitive.createdAt,
        text: PostText.empty,
        media: [photo()],
        url: '',
        sensitive: true,
      ).covered,
      isTrue,
    );
  });
}
