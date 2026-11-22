import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/common/media/media_origins.dart';
import 'package:mpx_example/social/src/common/media/post_media_facts.dart';
import 'package:mpx_example/social/src/feature/timeline/data/dto/mastodon_dto.dart';
import 'package:mpx_example/social/src/feature/timeline/data/status_html.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

/// A post and where its media live.
typedef AdaptedPost = ({Post post, Map<MediaKey, MediaOrigin> origins});

/// Maps a status as the server sent it to a [Post]: fields to fields, no
/// decoding and no network.
///
/// A boost shows the boosted status with the booster named; a post's media
/// are keyed by the server and the attachment's id, never by their URLs.
final class StatusAdapter {
  const StatusAdapter();

  /// The post of [status], read from [host].
  AdaptedPost fromStatus(StatusDto status, {required String host}) {
    final shown = status.reblog ?? status;
    final origins = <MediaKey, MediaOrigin>{};

    final media = <PostMedia>[];
    for (final attachment in shown.mediaAttachments) {
      final adapted = _media(attachment, host);
      if (adapted == null) continue;
      media.add(adapted.media);
      origins[adapted.media.key] = adapted.origin;
    }

    final author = _account(shown.account, host, origins);
    final booster = status.reblog == null
        ? null
        : _account(status.account, host, origins);

    return (
      post: Post(
        id: PostId(shown.id),
        host: host,
        author: author,
        createdAt: shown.createdAt,
        text: StatusHtml.parse(shown.content),
        media: media,
        url: shown.url ?? '',
        warning: shown.spoilerText,
        sensitive: shown.sensitive,
        boostedBy: booster,
        replies: shown.repliesCount,
        boosts: shown.reblogsCount,
        likes: shown.favouritesCount,
      ),
      origins: origins,
    );
  }

  Account _account(
    AccountDto dto,
    String host,
    Map<MediaKey, MediaOrigin> origins,
  ) {
    MediaKey? avatar;
    final url = dto.avatar;
    if (url != null && url.isNotEmpty) {
      avatar = _key(host, 'avatar/${dto.id}', url);
      origins[avatar] = MediaOrigin(
        content: Uri.parse(url),
        descriptor: MediaDescriptor(key: avatar, kind: MediaKind.still),
      );
    }
    return Account(
      handle: dto.acct.contains('@') ? dto.acct : '${dto.acct}@$host',
      displayName: dto.displayName.isEmpty ? dto.username : dto.displayName,
      avatar: avatar,
      bot: dto.bot,
    );
  }

  ({PostMedia media, MediaOrigin origin})? _media(
    MediaAttachmentDto dto,
    String host,
  ) {
    final url = dto.url;
    if (url == null) return null;
    final kind = switch (dto.type) {
      MediaAttachmentType.image => PostMediaKind.photo,
      MediaAttachmentType.video => PostMediaKind.video,
      MediaAttachmentType.gifv => PostMediaKind.gif,
      // Sound with no picture and kinds this client does not know are left
      // out rather than drawn as something else.
      MediaAttachmentType.audio || MediaAttachmentType.unknown => null,
    };
    if (kind == null) return null;
    final size = dto.meta?.original;
    final seconds = size?.duration;
    final bitrate = size?.bitrate;
    final key = MediaKey.external('$host/media/${dto.id}');
    final preview = dto.previewUrl;
    final media = PostMedia(
      key: key,
      kind: kind,
      width: size?.width,
      height: size?.height,
      duration: seconds == null
          ? null
          : Duration(microseconds: (seconds * 1e6).round()),
      // The server sends no size: a clip weighs about its bitrate for its
      // length, which is what the auto-download policy needs to weigh it.
      byteSize:
          kind == PostMediaKind.photo || seconds == null || bitrate == null
          ? null
          : (seconds * bitrate / 8).round(),
      alt: dto.description,
    );
    return (
      media: media,
      origin: MediaOrigin(
        content: Uri.parse(url),
        descriptor: PostMediaFacts.descriptor(media),
        preview: preview == null ? null : Uri.parse(preview),
        mimeType: kind == PostMediaKind.photo ? null : _mimeOf(url),
      ),
    );
  }

  static String _mimeOf(String url) =>
      switch (Uri.parse(url).path.split('.').last.toLowerCase()) {
        'webm' => 'video/webm',
        'mov' => 'video/quicktime',
        'mkv' => 'video/x-matroska',
        _ => 'video/mp4',
      };

  // A key of [host]'s [kind of thing], named by the file's own name, which
  // the server derives from its content: a new file is a new key.
  static MediaKey _key(String host, String of, String url) {
    final name = Uri.parse(
      url,
    ).pathSegments.lastWhere((segment) => segment.isNotEmpty, orElse: () => '');
    return MediaKey.external('$host/$of/$name');
  }
}
