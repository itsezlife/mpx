import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

/// One file the development upload server keeps, as `GET /files` lists it.
final class DevServerFile {
  const DevServerFile(this.id, this.size, this.contentType);

  final String id;
  final int size;
  final String contentType;

  /// The key the demo shows the file by: the server's identity for it.
  MediaKey get key => DevServer.keyOf(id);

  /// What the pipeline knows of the file before it fetches it.
  MediaDescriptor get descriptor => MediaDescriptor(
    key: key,
    kind: contentType.startsWith('video/')
        ? MediaKind.video
        : contentType.startsWith('image/')
        ? MediaKind.still
        : MediaKind.unknown,
    animated: contentType.startsWith('video/'),
    byteSize: size,
  );
}

/// The host side of the example's development upload server
/// (`tool/upload_server.dart`): its URLs, the host's own calls to it, the
/// three transports the demo sends through, the publisher and the resolver
/// of the files it keeps.
///
/// Every call goes through [client], so the debug panel's network cut
/// reaches them too.
final class DevServer {
  DevServer(this.base, {required http.Client client}) : _client = client;

  /// The server's base URL.
  final Uri base;

  final http.Client _client;

  static const String _keyPrefix = 'dev-';

  /// The key of the server's file [id].
  static MediaKey keyOf(String id) => MediaKey.remote('$_keyPrefix$id');

  /// The server's file id of [key], or null for a key of no server file.
  static String? fileOf(MediaKey key) => switch (key) {
    MediaKey$Remote(:final id) when id.startsWith(_keyPrefix) => id.substring(
      _keyPrefix.length,
    ),
    _ => null,
  };

  /// The URL of [path] on the server.
  Uri url(String path, [Map<String, String>? query]) => base.replace(
    path: path,
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  /// Where the server serves [key]'s file, or null for a key it does not
  /// keep.
  Uri? locationOf(MediaKey key) => switch (fileOf(key)) {
    final id? => url('/files/$id'),
    null => null,
  };

  /// The files the server keeps.
  Future<List<DevServerFile>> files() async {
    final response = await _client.get(url('/files'));
    _check(response);
    return [
      for (final entry
          in (jsonDecode(response.body) as List<Object?>)
              .cast<Map<String, Object?>>())
        DevServerFile(
          entry['id']! as String,
          entry['size']! as int,
          entry['contentType']! as String,
        ),
    ];
  }

  /// Switches the server's modes (`GET /control`); null leaves one as it
  /// is. Answers the modes after.
  Future<Map<String, Object?>> control({
    String? upload,
    String? publish,
    int? rateKiBs,
  }) async {
    final response = await _client.get(
      url('/control', {
        'upload': ?upload,
        'publish': ?publish,
        if (rateKiBs != null) 'rate': '$rateKiBs',
      }),
    );
    _check(response);
    return jsonDecode(response.body) as Map<String, Object?>;
  }

  static void _check(http.Response response) {
    if (response.statusCode != 200) {
      throw UploadTransportException(
        'server_status',
        status: response.statusCode,
      );
    }
  }

  // --- Transports -----------------------------------------------------------

  /// The three transports to the server, ids as [DemoTransport] names them:
  /// multipart, tus and numbered parts. [bytes] sends their part bodies.
  List<UploadTransport> transports(HttpBytesClient bytes) => [
    MultipartUploadTransport(
      request: (info) => MultipartUploadRequest(
        url('/multipart'),
        contentType: info.contentType,
      ),
      remoteRef: (response) => RemoteRef(
        (jsonDecode(utf8.decode(response.body ?? const []))
                as Map<String, Object?>)['id']!
            as String,
      ),
    ),
    TusUploadTransport(
      endpoint: url('/tus/'),
      client: bytes,
      remoteRef: (upload, headers) =>
          RemoteRef(headers['x-file-id'] ?? upload.pathSegments.last),
    ),
    NumberedPartsTransport(
      start: (info) async {
        final response = await _client.post(
          url('/numbered/start'),
          body: jsonEncode({
            'size': info.size,
            'parts': info.partCount,
            'contentType': ?info.contentType,
          }),
        );
        _check(response);
        return (jsonDecode(response.body) as Map<String, Object?>)['uploadId']!
            as String;
      },
      partRequest: (part) =>
          NumberedPartRequest(url('/numbered/${part.uploadId}/${part.number}')),
      receiptOf: (response) => response.headers['x-part-id'],
      complete: (completion) async {
        final response = await _client.post(
          url('/numbered/${completion.uploadId}/complete'),
          body: jsonEncode({
            'parts': [
              for (final part in completion.parts)
                {'number': part.number, 'id': part.receipt},
            ],
          }),
        );
        _check(response);
        return RemoteRef(
          (jsonDecode(response.body) as Map<String, Object?>)['file']!
              as String,
        );
      },
    ),
  ];
}

/// The demo's [Publisher]: hands the items' references and the payload to
/// the server's `POST /publish` with the job's idempotency key, and reads
/// its answer as a [PublishOutcome]. A published item's server key is the
/// server's file, so after the alias the item shows under it from the
/// cached bytes.
final class DevServerPublisher implements Publisher {
  DevServerPublisher(this._server, {required http.Client client})
    : _client = client;

  /// The id the demo registers it under.
  static const String id = 'dev.publish';

  final DevServer _server;
  final http.Client _client;

  @override
  Future<PublishOutcome> publish(
    Uint8List payload,
    Map<String, PublishItemRefs> items,
    String idempotencyKey,
  ) async {
    final response = await _client.post(
      _server.url('/publish'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'idempotencyKey': idempotencyKey,
        'payload': base64.encode(payload),
        'items': {
          for (final MapEntry(key: itemId, value: refs) in items.entries)
            itemId: {
              'key': refs.key.encoded,
              'file': ?refs.file?.id,
              'thumbnail': ?refs.thumbnail?.id,
            },
        },
      }),
    );
    if (response.statusCode != 200) {
      return PublishOutcome.rejected(
        reason: 'status_${response.statusCode}',
        retryable: response.statusCode >= 500,
      );
    }
    final json = jsonDecode(response.body) as Map<String, Object?>;
    return switch (json['outcome']) {
      'published' => PublishOutcome.published(
        serverKeys: {
          for (final MapEntry(key: itemId, :value)
              in ((json['serverKeys'] as Map<String, Object?>?) ?? const {})
                  .entries)
            itemId: DevServer.keyOf(value! as String),
        },
      ),
      'reupload' => PublishOutcome.reuploadItems(
        ((json['items'] as List<Object?>?) ?? const []).cast<String>(),
      ),
      _ => PublishOutcome.rejected(
        reason: (json['reason'] as String?) ?? 'rejected',
        retryable: (json['retryable'] as bool?) ?? false,
      ),
    };
  }
}

/// Describes the server's files for the pipeline and for tracked downloads
/// after a restart: one `GET /files` per batch, every other key left out.
final class DevServerResolver implements MediaResolver {
  DevServerResolver(this._server);

  final DevServer _server;

  @override
  Future<Map<MediaKey, MediaDescriptor>> resolve(
    Iterable<MediaKey> keys,
  ) async {
    final wanted = {
      for (final key in keys)
        if (DevServer.fileOf(key) != null) key,
    };
    if (wanted.isEmpty) return const {};
    final files = await _server.files();
    return {
      for (final file in files)
        if (wanted.contains(file.key)) file.key: file.descriptor,
    };
  }
}
