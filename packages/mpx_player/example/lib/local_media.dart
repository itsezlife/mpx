import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';
import 'package:mpx_core/mpx_core.dart';
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
    this.backend,
  );

  /// A 12 s clip with sound.
  static const MediaKey clip = MediaKey.remote('clip');

  /// Bytes that are no video.
  static const MediaKey garbage = MediaKey.remote('garbage');

  final HttpServer _server;
  final Directory _directory;
  final IBytesStore _store;
  final HttpBytesClient _client;
  final RangedBytes _ranged;
  final NativeRangedReaders _readers;

  /// The platform backend over the cache.
  final NativePlayerBackend backend;

  /// Serves the bundled clip and opens a fresh cache.
  static Future<LocalMedia> start() async {
    final data = await rootBundle.load('assets/clip.mp4');
    final noise = Random(7);
    final files = <String, Uint8List>{
      'clip': data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      'garbage': Uint8List.fromList(
        List.generate(64 * 1024, (_) => noise.nextInt(256)),
      ),
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => _serve(request, files));
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
      sourcesOf: (key) => switch (key) {
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
    return LocalMedia._(
      server,
      directory,
      store,
      client,
      ranged,
      readers,
      backend,
    );
  }

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
    final body = files[request.uri.pathSegments.lastOrNull];
    if (body == null) {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentType = ContentType('video', 'mp4');
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
}
