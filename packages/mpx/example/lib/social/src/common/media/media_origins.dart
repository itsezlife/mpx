import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';

/// Where one piece of media lives on the web.
final class MediaOrigin {
  const MediaOrigin({
    required this.content,
    required this.descriptor,
    this.preview,
    this.mimeType,
  });

  /// The file itself.
  final Uri content;

  /// A small still of it, for the stand-in.
  final Uri? preview;

  /// The video's container type, for the platform player.
  final String? mimeType;

  /// What the host knows of the media, told to the cache as it arrives, so
  /// the preview and thumbnail show though the cache never saw it.
  final MediaDescriptor descriptor;
}

/// What the host knows of where each media key lives: the stack's fetcher and
/// the players ask it, and the data layer fills it as posts arrive.
///
/// A media key never carries a URL (ADR 0001); this is the host's map from
/// one to the other. It holds a few strings per media the session has seen.
final class MediaOrigins {
  final Map<MediaKey, MediaOrigin> _byKey = {};

  /// Where the descriptors of arriving media go: the stack's pipeline. Set
  /// once the stack exists, since the stack's fetcher asks these origins.
  void Function(MediaDescriptor descriptor)? tellCache;

  /// Remembers where [key] lives, and tells the cache what it is.
  void know(MediaKey key, MediaOrigin origin) {
    _byKey[key] = origin;
    tellCache?.call(origin.descriptor);
  }

  /// The origin of [key], or null when none is known.
  MediaOrigin? of(MediaKey key) => _byKey[key];

  /// The stack's `MediaLocator`: the preview for a thumbnail part, the file
  /// for the content.
  MediaLocation? locate(MediaDescriptor descriptor, FetchPart part) {
    final origin = _byKey[descriptor.key];
    if (origin == null) return null;
    final uri = switch (part) {
      FetchPart.thumbnail => origin.preview,
      FetchPart.content => origin.content,
    };
    return uri == null ? null : MediaLocation(uri.toString());
  }

  /// The sources the platform player reads [key] from, as the player
  /// backend asks.
  List<PlayerSource> playerSources(
    MediaKey key,
    BytesCacheKey Function(MediaKey key) cacheKeyOf,
  ) => switch (_byKey[key]) {
    final origin? => [
      PlayerSource(
        RangedRequest(url: origin.content, cacheKey: cacheKeyOf(key)),
        mimeType: origin.mimeType ?? 'video/mp4',
      ),
    ],
    null => const <PlayerSource>[],
  };
}
