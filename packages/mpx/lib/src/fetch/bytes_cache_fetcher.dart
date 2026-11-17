import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/src/fetch/ranged_content_publisher.dart';
import 'package:mpx_core/mpx_core.dart';

/// Where one part of a piece of media is on the network, as the host's
/// [MediaLocator] answers it.
@immutable
final class MediaLocation {
  /// Creates a location at [url].
  const MediaLocation(
    this.url, {
    this.headers,
    this.revalidation = RevalidationPolicy.immutable,
    this.quota,
  });

  /// The absolute URL of the bytes. It may change between calls (signed or
  /// expiring URLs): the cache keys the bytes by media key, not by URL.
  final String url;

  /// Sent with the GET; not part of the cache identity.
  final Map<String, String>? headers;

  /// What a held copy costs. Media under a media key never changes, so the
  /// default serves a held copy without asking the origin; a mutable
  /// resource (an avatar) passes [RevalidationPolicy.staleWhileRevalidate].
  final RevalidationPolicy revalidation;

  /// The store quota the bytes count against; null is the store's default
  /// (images).
  final BytesQuota? quota;
}

/// The host's answer to "where are the bytes of [part] of [descriptor]?", or
/// null when it has none (the fetch then fails permanently).
///
/// Called only when the cache does not hold the part, so a lookup it needs
/// (an API call by id) costs nothing for held media. It may complete later;
/// a lookup that throws fails the fetch transiently.
typedef MediaLocator =
    FutureOr<MediaLocation?> Function(
      MediaDescriptor descriptor,
      FetchPart part,
    );

/// A [ContentFetcher] over `http_bytes_cache`: the core's fetch seam filled
/// from one bytes store and one HTTP client.
///
/// Media is keyed in the store by [cacheKeyOf] (the media key's stable form),
/// never by URL. A part the store holds is served from it with no lookup and
/// no progress report. Otherwise the host's [MediaLocator] names the URL and
/// the cache's resolve ladder fetches it: concurrent fetches of one part share
/// one GET, each hears its progress, and the bytes are written through.
///
/// - Cancelling a fetch settles it at once with a transient failure. The GET
///   runs on while another fetch shares it, and stops with its last caller.
/// - Failures: a missing location, 4xx (but 408 and 429) and 401/403 are
///   permanent; no network, timeouts, 5xx, 408, 429 and any other error are
///   transient.
/// - [needsDownload] reads the store's RAM index and the GETs in flight; it
///   never waits.
/// - Priorities map onto the client's slot queue: placeholder and visible
///   work is visible, preload work is preload.
///
/// ## What goes out
///
/// Over a store that keeps files (the VM store) content goes out as the
/// file it is in ([FetchedFile]), leased until the decoder releases it, so
/// its bytes never pass through this isolate. With [ranged], a missing
/// part whose location is immutable is fetched into the store as a ranged
/// resource (in parts, several in flight, through the client's transfer
/// worker when it has one) and goes out as its file too. With [publisher], missing
/// content of the kinds it takes goes out published instead
/// ([FetchedRanged]): the decoder reads it natively as it downloads. Over a
/// store without files (memory, the web), or for a location that asks for
/// revalidation, content goes out as bytes through the resolve ladder.
final class BytesCacheFetcher implements ContentFetcher {
  /// Creates a fetcher over [store] and [client], locating parts with
  /// [locate]. Neither the store, the client, [ranged] nor [publisher] is
  /// closed by it. [ranged] must be over [store].
  BytesCacheFetcher({
    required IBytesStore store,
    required HttpBytesClient client,
    required MediaLocator locate,
    RangedBytes? ranged,
    RangedContentPublisher? publisher,
  }) : _store = store,
       _locate = locate,
       _ranged = ranged != null && ranged.isSupported ? ranged : null,
       _publisher = publisher,
       _resolver = BytesResolver(cache: store, client: client);

  final IBytesStore _store;
  final MediaLocator _locate;
  final RangedBytes? _ranged;
  final RangedContentPublisher? _publisher;
  final BytesResolver _resolver;

  // --- Cache keys ---

  /// The cache key of [part] of [key].
  ///
  /// Content is the media key's stable form (`MediaKey.encoded`, already
  /// filename-safe); a thumbnail is that form behind a `thumbnail-` prefix,
  /// which no stable form starts with. Keyed by media, not by the thumbnail
  /// reference, because a host may hand out a new reference (a URL with a
  /// per-answer tag) for the same stand-in. A form longer than the store
  /// takes is replaced by `hashed-` and its SHA-1.
  static BytesCacheKey cacheKeyOf(MediaKey key, FetchPart part) {
    final form = switch (part) {
      FetchPart.content => key.encoded,
      FetchPart.thumbnail => 'thumbnail-${key.encoded}',
    };
    if (form.length <= _maxKeyLength) return BytesCacheKey(form);
    return BytesCacheKey('hashed-${sha1.convert(utf8.encode(form))}');
  }

  // The longest value `BytesCacheKey.fromUrl` produces; the stores take it
  // as a file name and a web cache key.
  static const int _maxKeyLength = 180;

  // --- ContentFetcher ---

  @override
  Future<FetchedContent> fetch(FetchRequest request) {
    final settled = Completer<FetchedContent>();
    final cancel = CancelToken();
    request.cancellation.onCancel(() {
      cancel.cancel();
      if (!settled.isCompleted) {
        settled.completeError(const FetchFailure.transient('cancelled'));
      }
    });
    if (!settled.isCompleted) {
      _fetch(request, cancel).then(
        (content) {
          if (settled.isCompleted) {
            // Settled by the cancel: nobody takes this content.
            content.release();
          } else {
            settled.complete(content);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!settled.isCompleted) {
            settled.completeError(_failureOf(error), stackTrace);
          }
        },
      );
    }
    return settled.future;
  }

  @override
  bool needsDownload(MediaKey key) =>
      _resolver.peek(_probe(cacheKeyOf(key, FetchPart.content))) !=
      BytesPeek.cached;

  Future<FetchedContent> _fetch(
    FetchRequest request,
    CancelToken cancel,
  ) async {
    final key = cacheKeyOf(request.descriptor.key, request.part);
    if (_store.contains(key)) {
      final lease = await _store.leaseFile(key);
      if (lease != null) {
        return FetchedContent.file(lease.path, onRelease: lease.release);
      }
      final held = await _store.read(key);
      if (held != null && held.isNotEmpty) return FetchedContent.bytes(held);
    }
    final location = await _locate(request.descriptor, request.part);
    if (location == null) {
      throw FetchFailure.permanent(
        'no location for the ${request.part.name} of ${request.descriptor.key}',
      );
    }
    final ranged = _ranged;
    if (ranged != null &&
        location.revalidation == RevalidationPolicy.immutable) {
      final rangedRequest = RangedRequest(
        url: Uri.parse(location.url),
        cacheKey: key,
        headers: location.headers,
        quota: location.quota ?? BytesQuota.images,
      );
      final publisher = _publisher;
      if (publisher != null &&
          request.part == FetchPart.content &&
          request.prefix == null &&
          publisher.kinds.contains(request.descriptor.kind)) {
        return publisher.publish(
          rangedRequest,
          priority: PriorityToken(_priorityOf(request.priority)),
          cancelToken: cancel,
        );
      }
      return _fetchWhole(ranged, rangedRequest, request, cancel);
    }
    final bytes = await _resolver.resolve(
      BytesRequest(
        url: location.url,
        headers: location.headers,
        cacheKey: key,
        cancelToken: cancel,
        onBytesProgress: request.onProgress,
        priority: PriorityToken(_priorityOf(request.priority)),
        revalidation: location.revalidation,
        quota: location.quota,
      ),
    );
    return FetchedContent.bytes(bytes);
  }

  /// Fetches the whole of [rangedRequest] into the store and hands out its
  /// file, held until released.
  Future<FetchedContent> _fetchWhole(
    RangedBytes ranged,
    RangedRequest rangedRequest,
    FetchRequest request,
    CancelToken cancel,
  ) async {
    final resource = await ranged.open(rangedRequest);
    var reported = false;
    void report() {
      reported = true;
      request.onProgress(resource.ranges.coveredBytes, resource.totalLength);
    }

    final events = resource.events.listen((event) {
      if (event is RangeLanded) report();
    });
    try {
      await resource.ensure(
        const ByteRange(0),
        priority: PriorityToken(_priorityOf(request.priority)),
        cancelToken: cancel,
      );
    } on Object {
      await events.cancel();
      await resource.close();
      rethrow;
    }
    await events.cancel();
    if (reported) report();
    return FetchedContent.file(
      resource.path,
      onRelease: () => unawaited(resource.close()),
    );
  }

  // A request that only names the key: what `peek` reads.
  static BytesRequest _probe(BytesCacheKey key) =>
      BytesRequest(url: '', cacheKey: key);

  static RequestPriority _priorityOf(AssetPriority priority) =>
      switch (priority) {
        AssetPriority.placeholder ||
        AssetPriority.visible => RequestPriority.visible,
        AssetPriority.preload => RequestPriority.preload,
      };

  // --- Failures ---

  static FetchFailure _failureOf(Object error) => switch (error) {
    FetchFailure() => error,
    HttpBytesException$Request(statusCode: 408 || 429) =>
      FetchFailure.transient(error.message, error),
    HttpBytesException$Request() => FetchFailure.permanent(
      error.message,
      error,
    ),
    HttpBytesException$Authentication() => FetchFailure.permanent(
      error.message,
      error,
    ),
    HttpBytesException() => FetchFailure.transient(error.message, error),
    _ => FetchFailure.transient('$error', error),
  };
}
