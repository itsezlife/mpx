import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/native.dart';

/// The example's media on a loopback origin that answers range requests,
/// fetched into a bytes cache and played by the platform backend through
/// the cache's native reader: the same path a real host's CDN bytes take.
final class LocalMedia {
  LocalMedia._(
    this._server,
    this._directory,
    this._store,
    this._client,
    this._ranged,
    this._readers,
    this._origin,
    this.backend,
  );

  /// A 12 s clip with sound.
  static const MediaKey clip = MediaKey.remote('clip');

  /// The same clip as an HLS stream (three 4 s segments), with the MP4 as
  /// the fallback for players that open progressive files only (Apple).
  static const MediaKey stream = MediaKey.remote('stream');

  /// Bytes that are no video.
  static const MediaKey garbage = MediaKey.remote('garbage');

  final HttpServer _server;
  final Directory _directory;
  final IBytesStore _store;
  final HttpBytesClient _client;
  final RangedBytes _ranged;
  final NativeRangedReaders _readers;
  final Uri _origin;

  /// The platform backend over the cache.
  final NativePlayerBackend backend;

  /// Serves the bundled clip and opens a fresh cache.
  static Future<LocalMedia> start() async {
    Future<Uint8List> asset(String name) async {
      final data = await rootBundle.load('assets/$name');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    final noise = Random(7);
    final files = <String, Uint8List>{
      'clip': await asset('clip.mp4'),
      'garbage': Uint8List.fromList(
        List.generate(64 * 1024, (_) => noise.nextInt(256)),
      ),
      for (final part in _streamParts)
        'stream/$part': await asset('stream/$part'),
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late final LocalMedia media;
    server.listen((request) {
      if (!media.originOnline) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        unawaited(request.response.close());
        return;
      }
      media._requests.add(request.uri.path);
      unawaited(_serve(request, files));
    });
    final directory = await Directory.systemTemp.createTemp('mpx_player_');
    final store = await BytesCache.open(
      directory: directory.path,
      throwOnOpenFailure: true,
    );
    final client = HttpBytesClient();
    final ranged = RangedBytes(store: store, client: client);
    final readers = NativeRangedReaders(ranged);
    final origin = Uri.parse('http://127.0.0.1:${server.port}');
    final backend = NativePlayerBackend(
      readers: readers,
      backgroundAudio: true,
      playlists: BytesResolver(cache: store, client: client),
      sourcesOf: (key) => switch (key) {
        MediaKey$Remote(id: 'stream') => [
          PlayerSource.hls(
            RangedRequest(
              url: origin.resolve('/stream/index.m3u8'),
              cacheKey: const BytesCacheKey('player-stream'),
            ),
          ),
          PlayerSource(
            RangedRequest(
              url: origin.resolve('/clip'),
              cacheKey: const BytesCacheKey('player-clip'),
            ),
          ),
        ],
        MediaKey$Remote(:final id) when files.containsKey(id) => [
          PlayerSource(
            RangedRequest(
              url: origin.resolve('/$id'),
              cacheKey: BytesCacheKey('player-$id'),
            ),
          ),
        ],
        _ => const [],
      },
    );
    return media = LocalMedia._(
      server,
      directory,
      store,
      client,
      ranged,
      readers,
      origin,
      backend,
    );
  }

  /// Publishes [key]'s bytes to the native reader as content a decoder
  /// reads in place (a still extractor); releasing it withdraws them.
  Future<FetchedContent> publish(MediaKey key) async {
    final id = (key as MediaKey$Remote).id;
    final cacheKey = BytesCacheKey('content-$id');
    final publication = await _readers.publish(
      RangedRequest(url: _origin.resolve('/$id'), cacheKey: cacheKey),
    );
    return FetchedContent.ranged(
      readerApi: NativeRangedReaders.apiAddress,
      key: cacheKey.value,
      onRelease: () => unawaited(publication.close()),
    );
  }

  final List<String> _requests = [];

  /// The paths the origin was asked for, in order.
  List<String> get originRequests => List.unmodifiable(_requests);

  /// Whether the origin answers; offline, as in airplane mode, it fails
  /// every request and what plays comes from the cache.
  bool originOnline = true;

  /// Stops everything and deletes the cache.
  Future<void> close() async {
    backend.dispose();
    await _readers.close();
    await _ranged.close();
    await _client.close();
    await _store.close();
    await _server.close(force: true);
    await _directory.delete(recursive: true);
  }

  static Future<void> _serve(
    HttpRequest request,
    Map<String, Uint8List> files,
  ) async {
    final response = request.response;
    final path = request.uri.path.substring(1);
    final body = files[path];
    if (body == null) {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = switch (path.split('.').last) {
        'm3u8' => ContentType('application', 'vnd.apple.mpegurl'),
        'ts' => ContentType('video', 'mp2t'),
        _ => ContentType('video', 'mp4'),
      };
    final range = RegExp(
      r'bytes=(\d+)-(\d*)',
    ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (range == null) {
      response.contentLength = body.length;
      response.add(body);
      return response.close();
    }
    final start = int.parse(range.group(1)!);
    final last = range.group(2)!.isEmpty
        ? body.length - 1
        : min(int.parse(range.group(2)!), body.length - 1);
    response
      ..statusCode = HttpStatus.partialContent
      ..headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$last/${body.length}',
      )
      ..contentLength = last - start + 1
      ..add(body.sublist(start, last + 1));
    return response.close();
  }

  static const List<String> _streamParts = [
    'index.m3u8',
    'seg-0.ts',
    'seg-1.ts',
    'seg-2.ts',
  ];
}
