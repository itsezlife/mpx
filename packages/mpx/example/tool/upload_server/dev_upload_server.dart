import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// How the server answers uploads: normally, or with an error the client
/// retries.
enum UploadMode {
  /// Takes every part.
  ok,

  /// Answers every upload request 503, a failure that may pass.
  fail,
}

/// How the server answers a publish.
enum PublishMode {
  /// Publishes: answers each uploaded item's file id as its server key.
  ok,

  /// Refuses the publish for good.
  reject,

  /// Refuses the publish, saying a later try may pass.
  rejectRetryable,

  /// Asks for every uploaded item again, once per idempotency key; the
  /// next publish with that key is published.
  reupload,
}

/// One file the server keeps: an upload it completed or a file put in its
/// folder by hand.
final class ServedFile {
  ServedFile(this.id, this.size, this.contentType);

  final String id;
  final int size;
  final String contentType;

  Map<String, Object?> toJson() => {
    'id': id,
    'size': size,
    'contentType': contentType,
  };
}

/// A development upload server for the example's transfers demo, on the
/// LAN: three upload protocols, a publish endpoint and the files it keeps.
///
/// - `POST /multipart`: one `multipart/form-data` request; answers
///   `{"id", "size"}`.
/// - `/tus/`: the tus resumable upload protocol (core, creation,
///   expiration); the last `PATCH` answers the file id in `x-file-id`.
/// - `/numbered/`: numbered parts: `POST /numbered/start` answers
///   `{"uploadId"}`, `PUT /numbered/<id>/<n>` takes part n and answers
///   `x-part-id`, `POST /numbered/<id>/complete` takes
///   `{"parts": [{"number", "id"}]}` and answers `{"file"}`.
/// - `POST /publish`: `{"idempotencyKey", "items": {itemId: {"file"}}}`,
///   answered by [publishMode]; every call is counted by its key
///   (`GET /publishes`), so a duplicated publish shows.
/// - `GET /files` lists the files kept in [directory]; `GET /files/<id>`
///   serves one, with ranges.
/// - `GET /control?upload=ok|fail&publish=ok|reject|rejectRetryable|reupload&rate=<KiB/s>`
///   switches the modes (`rate=0` for no limit) and answers them.
///
/// [rateBytesPerSecond] slows every body read and written, so a device
/// check has time to kill or background the app mid-transfer.
final class DevUploadServer {
  DevUploadServer._(this._server, this.directory, this.log) {
    _server.listen((request) => unawaited(_handle(request)));
    _scan();
  }

  /// Binds [port] on every interface ([address]) and keeps files in
  /// [directory]. [log] hears one line per request.
  static Future<DevUploadServer> start({
    required Directory directory,
    int port = 8090,
    InternetAddress? address,
    void Function(String line)? log,
  }) async {
    directory.createSync(recursive: true);
    final server = await HttpServer.bind(
      address ?? InternetAddress.anyIPv4,
      port,
    );
    return DevUploadServer._(server, directory, log ?? (_) {});
  }

  final HttpServer _server;

  /// Where the files are kept.
  final Directory directory;

  /// Hears one line per request.
  final void Function(String line) log;

  /// The port the server listens on.
  int get port => _server.port;

  /// How uploads are answered.
  UploadMode uploadMode = UploadMode.ok;

  /// How publishes are answered.
  PublishMode publishMode = PublishMode.ok;

  /// The most body bytes moved per second, or null for no limit.
  int? rateBytesPerSecond;

  final Map<String, ServedFile> _files = {};
  final Map<String, int> _publishes = {};
  final Set<String> _reuploadAsked = {};
  final Map<String, _TusUpload> _tus = {};
  final Map<String, Map<int, Uint8List>> _numbered = {};
  final Map<String, String> _numberedTypes = {};
  int _next = 0;

  /// The files kept, by id.
  Map<String, ServedFile> get files => Map.unmodifiable(_files);

  /// How many publishes each idempotency key received.
  Map<String, int> get publishes => Map.unmodifiable(_publishes);

  /// The modes as `GET /control` answers them.
  Map<String, Object?> get modes => {
    'upload': uploadMode.name,
    'publish': publishMode.name,
    'rateKiBs': switch (rateBytesPerSecond) {
      final rate? => rate ~/ 1024,
      null => 0,
    },
  };

  /// Applies `upload`, `publish` and `rate` (KiB/s, 0 for none) from
  /// [query]; unknown values are left as they were.
  void control(Map<String, String> query) {
    if (query['upload'] case final value?) {
      uploadMode = UploadMode.values.asNameMap()[value] ?? uploadMode;
    }
    if (query['publish'] case final value?) {
      publishMode = PublishMode.values.asNameMap()[value] ?? publishMode;
    }
    if (int.tryParse(query['rate'] ?? '') case final rate?) {
      rateBytesPerSecond = rate <= 0 ? null : rate * 1024;
    }
  }

  Future<void> close() => _server.close(force: true);

  // --- Files ----------------------------------------------------------------

  void _scan() {
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('.')) continue;
      _files[name] = ServedFile(name, entity.lengthSync(), _typeOf(name));
      final number = int.tryParse(
        RegExp(r'^f(\d+)').firstMatch(name)?.group(1) ?? '',
      );
      if (number != null) _next = math.max(_next, number);
    }
  }

  ServedFile _keep(Uint8List bytes, String? contentType) {
    final type = contentType ?? 'application/octet-stream';
    final id = 'f${++_next}${_extensionOf(type)}';
    File('${directory.path}/$id').writeAsBytesSync(bytes, flush: true);
    return _files[id] = ServedFile(id, bytes.length, type);
  }

  static String _typeOf(String name) =>
      switch (name.split('.').last.toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'mp4' || 'm4v' => 'video/mp4',
        'mov' => 'video/quicktime',
        'webm' => 'video/webm',
        _ => 'application/octet-stream',
      };

  static String _extensionOf(String type) => switch (type) {
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    'image/gif' => '.gif',
    'image/webp' => '.webp',
    'image/heic' => '.heic',
    'video/mp4' => '.mp4',
    'video/quicktime' => '.mov',
    'video/webm' => '.webm',
    _ => '.bin',
  };

  // --- Dispatch -------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    try {
      response.headers
        ..set('access-control-allow-origin', '*')
        ..set('access-control-allow-headers', '*')
        ..set('access-control-allow-methods', '*')
        ..set(
          'access-control-expose-headers',
          'location, upload-offset, upload-length, upload-expires, '
              'tus-resumable, x-part-id, x-file-id, etag, content-range',
        );
      if (request.method == 'OPTIONS') {
        await request.drain<void>();
        response.statusCode = 204;
      } else if (path == '/control') {
        await request.drain<void>();
        control(request.uri.queryParameters);
        _json(response, 200, modes);
      } else if (path == '/health') {
        await request.drain<void>();
        _json(response, 200, {'ok': true, ...modes});
      } else if (path == '/publishes') {
        await request.drain<void>();
        _json(response, 200, publishes);
      } else if (path == '/files' && request.method == 'GET') {
        await request.drain<void>();
        _json(response, 200, [for (final file in _files.values) file.toJson()]);
      } else if (path.startsWith('/files/') && request.method == 'GET') {
        await _serve(request, path.substring('/files/'.length));
      } else if (path == '/publish' && request.method == 'POST') {
        await _publish(request);
      } else if (_isUpload(path) && uploadMode == UploadMode.fail) {
        await request.drain<void>();
        response.statusCode = 503;
      } else if (path == '/multipart' && request.method == 'POST') {
        await _multipart(request);
      } else if (path.startsWith('/tus/')) {
        await _tusRequest(request);
      } else if (path.startsWith('/numbered/')) {
        await _numberedRequest(request);
      } else {
        await request.drain<void>();
        response.statusCode = 404;
      }
      log('${request.method} $path ${response.statusCode}');
      await response.close();
    } on Object catch (error) {
      // The client went away mid-body: what was read is kept.
      log('${request.method} $path dropped ($error)');
      try {
        await response.close();
      } on Object {
        // Already gone.
      }
    }
  }

  static bool _isUpload(String path) =>
      path == '/multipart' ||
      path.startsWith('/tus/') ||
      path.startsWith('/numbered/');

  static void _json(HttpResponse response, int status, Object? body) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }

  // Reads [request]'s body at the rate, each chunk to [sink].
  Future<void> _read(HttpRequest request, void Function(List<int>) sink) async {
    final watch = Stopwatch()..start();
    var read = 0;
    await for (final chunk in request) {
      sink(chunk);
      read += chunk.length;
      await _pace(watch, read);
    }
  }

  Future<Uint8List> _readAll(HttpRequest request) async {
    final body = BytesBuilder(copy: false);
    await _read(request, body.add);
    return body.takeBytes();
  }

  Future<void> _pace(Stopwatch watch, int bytes) async {
    final rate = rateBytesPerSecond;
    if (rate == null) return;
    final due = Duration(microseconds: bytes * 1000000 ~/ rate);
    final ahead = due - watch.elapsed;
    if (ahead > Duration.zero) await Future<void>.delayed(ahead);
  }

  // --- Downloads ------------------------------------------------------------

  Future<void> _serve(HttpRequest request, String id) async {
    await request.drain<void>();
    // Closed by the dispatch, as every answer is.
    // ignore: close_sinks
    final response = request.response;
    final file = _files[id];
    if (file == null) {
      response.statusCode = 404;
      return;
    }
    final source = File('${directory.path}/$id');
    var start = 0;
    var end = file.size - 1;
    final range = RegExp(
      r'^bytes=(\d+)-(\d*)$',
    ).firstMatch(request.headers.value('range') ?? '');
    response.headers
      ..set('accept-ranges', 'bytes')
      ..contentType = ContentType.parse(file.contentType);
    if (range != null && file.size > 0) {
      start = int.parse(range.group(1)!);
      if (int.tryParse(range.group(2)!) case final last?) {
        end = math.min(last, file.size - 1);
      }
      if (start > end) {
        response
          ..statusCode = 416
          ..headers.set('content-range', 'bytes */${file.size}');
        return;
      }
      response
        ..statusCode = 206
        ..headers.set('content-range', 'bytes $start-$end/${file.size}');
    } else {
      response.statusCode = 200;
    }
    response.contentLength = end - start + 1;
    if (file.size == 0) return;
    final watch = Stopwatch()..start();
    var sent = 0;
    await for (final chunk in source.openRead(start, end + 1)) {
      response.add(chunk);
      sent += chunk.length;
      await _pace(watch, sent);
    }
  }

  // --- Multipart ------------------------------------------------------------

  Future<void> _multipart(HttpRequest request) async {
    final response = request.response;
    final type = request.headers.value('content-type') ?? '';
    final boundary = RegExp('boundary=(.+)').firstMatch(type)?.group(1);
    final body = await _readAll(request);
    if (!type.startsWith('multipart/form-data') || boundary == null) {
      response.statusCode = 415;
      return;
    }
    final file = _fileOfForm(body, boundary);
    if (file == null) {
      response.statusCode = 400;
      return;
    }
    final kept = _keep(file.bytes, file.contentType);
    _json(response, 200, {'id': kept.id, 'size': kept.size});
  }

  static ({Uint8List bytes, String? contentType})? _fileOfForm(
    Uint8List body,
    String boundary,
  ) {
    final delimiter = utf8.encode('--$boundary');
    final starts = <int>[];
    for (var at = _find(body, delimiter, 0); at >= 0;) {
      starts.add(at);
      at = _find(body, delimiter, at + delimiter.length);
    }
    for (var i = 0; i < starts.length - 1; i++) {
      final from = starts[i] + delimiter.length + 2;
      final to = starts[i + 1] - 2;
      if (to <= from) continue;
      final part = Uint8List.sublistView(body, from, to);
      final split = _find(part, const [13, 10, 13, 10], 0);
      if (split < 0) return null;
      final headers = latin1.decode(part.sublist(0, split)).toLowerCase();
      if (!headers.contains('filename=')) continue;
      final contentType = RegExp(
        r'content-type:\s*([^\r\n]+)',
      ).firstMatch(headers)?.group(1)?.trim();
      return (bytes: part.sublist(split + 4), contentType: contentType);
    }
    return null;
  }

  static int _find(List<int> haystack, List<int> needle, int from) {
    outer:
    for (var i = from; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  // --- tus ------------------------------------------------------------------

  static const String _tusVersion = '1.0.0';

  Future<void> _tusRequest(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    response.headers.set('tus-resumable', _tusVersion);
    if (request.headers.value('tus-resumable') != _tusVersion) {
      await request.drain<void>();
      response
        ..statusCode = 412
        ..headers.set('tus-version', _tusVersion);
      return;
    }
    switch (request.method) {
      case 'POST' when path == '/tus/':
        await request.drain<void>();
        final length = int.tryParse(
          request.headers.value('upload-length') ?? '',
        );
        if (length == null || length < 0) {
          response.statusCode = 400;
          return;
        }
        final uploadPath = '/tus/${++_next}';
        _tus[uploadPath] = _TusUpload(
          length,
          _metadataType(request.headers.value('upload-metadata')),
          DateTime.now().add(const Duration(hours: 24)),
        );
        response
          ..statusCode = 201
          ..headers.set('location', uploadPath);
        _expires(response, _tus[uploadPath]!);
      case 'HEAD':
        await request.drain<void>();
        final upload = _tus[path];
        response.headers.set('cache-control', 'no-store');
        if (upload == null) {
          response.statusCode = 404;
          return;
        }
        response
          ..statusCode = 200
          ..headers.set('upload-offset', '${upload.offset}')
          ..headers.set('upload-length', '${upload.length}');
        if (upload.fileId case final id?) {
          response.headers.set('x-file-id', id);
        }
        _expires(response, upload);
      case 'PATCH':
        final upload = _tus[path];
        final offset = int.tryParse(
          request.headers.value('upload-offset') ?? '',
        );
        if (upload == null) {
          await request.drain<void>();
          response.statusCode = 404;
          return;
        }
        if (offset != upload.offset) {
          await request.drain<void>();
          response.statusCode = 409;
          return;
        }
        // What arrives is kept, even when the client goes away midway, as
        // a tus server keeps a body broken off.
        await _read(request, (chunk) {
          final room = upload.length - upload.offset;
          upload.bytes.add(
            chunk.length > room ? chunk.sublist(0, room) : chunk,
          );
        });
        if (upload.offset == upload.length && upload.fileId == null) {
          upload.fileId = _keep(
            Uint8List.fromList(upload.bytes.toBytes()),
            upload.contentType,
          ).id;
        }
        response
          ..statusCode = 204
          ..headers.set('upload-offset', '${upload.offset}');
        if (upload.fileId case final id?) {
          response.headers.set('x-file-id', id);
        }
        _expires(response, upload);
      default:
        await request.drain<void>();
        response.statusCode = 405;
    }
  }

  static String? _metadataType(String? metadata) {
    for (final pair in (metadata ?? '').split(',')) {
      final parts = pair.trim().split(' ');
      if (parts.length == 2 &&
          (parts.first == 'filetype' || parts.first == 'contentType')) {
        try {
          return utf8.decode(base64.decode(parts[1]));
        } on FormatException {
          return null;
        }
      }
    }
    return null;
  }

  static void _expires(HttpResponse response, _TusUpload upload) =>
      response.headers.set('upload-expires', HttpDate.format(upload.expires));

  // --- Numbered parts -------------------------------------------------------

  Future<void> _numberedRequest(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments.skip(1).toList();
    switch ((request.method, segments)) {
      case ('POST', ['start']):
        final body = await _readAll(request);
        final id = 'n${++_next}';
        _numbered[id] = {};
        final json = _decode(body);
        if (json?['contentType'] case final String type) {
          _numberedTypes[id] = type;
        }
        _json(response, 200, {'uploadId': id});
      case ('PUT', [final id, final number]):
        final parts = _numbered[id];
        final index = int.tryParse(number);
        if (parts == null || index == null) {
          await request.drain<void>();
          response.statusCode = 404;
          return;
        }
        final body = await _readAll(request);
        parts[index] = body;
        response
          ..statusCode = 200
          ..headers.set('x-part-id', '$id-$index-${body.length}');
      case ('POST', [final id, 'complete']):
        final listed = _decode(await _readAll(request))?['parts'];
        final parts = _numbered[id];
        if (parts == null || listed is! List<Object?> || listed.isEmpty) {
          response.statusCode = 400;
          return;
        }
        final file = BytesBuilder(copy: false);
        for (final entry in listed) {
          if (entry is! Map<String, Object?>) continue;
          final number = entry['number'];
          final bytes = number is int ? parts[number] : null;
          if (bytes == null || entry['id'] != '$id-$number-${bytes.length}') {
            response.statusCode = 400;
            return;
          }
          file.add(bytes);
        }
        _numbered.remove(id);
        final kept = _keep(file.takeBytes(), _numberedTypes.remove(id));
        _json(response, 200, {'file': kept.id});
      default:
        await request.drain<void>();
        response.statusCode = 404;
    }
  }

  static Map<String, Object?>? _decode(Uint8List body) {
    try {
      final json = jsonDecode(utf8.decode(body));
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }

  // --- Publish --------------------------------------------------------------

  Future<void> _publish(HttpRequest request) async {
    final response = request.response;
    final json = _decode(await _readAll(request));
    final key = json?['idempotencyKey'];
    final items = json?['items'];
    if (key is! String || items is! Map<String, Object?>) {
      response.statusCode = 400;
      return;
    }
    _publishes[key] = (_publishes[key] ?? 0) + 1;
    final uploaded = <String, String>{
      for (final MapEntry(key: itemId, value: refs) in items.entries)
        if (refs case {'file': final String file}) itemId: file,
    };
    switch (publishMode) {
      case PublishMode.reject:
        _json(response, 200, {
          'outcome': 'rejected',
          'reason': 'server_rejected',
          'retryable': false,
        });
      case PublishMode.rejectRetryable:
        _json(response, 200, {
          'outcome': 'rejected',
          'reason': 'server_busy',
          'retryable': true,
        });
      case PublishMode.reupload when _reuploadAsked.add(key):
        _json(response, 200, {
          'outcome': 'reupload',
          'items': uploaded.keys.toList(),
        });
      case PublishMode.ok || PublishMode.reupload:
        _json(response, 200, {
          'outcome': 'published',
          'serverKeys': {
            for (final MapEntry(key: itemId, value: file) in uploaded.entries)
              if (_files.containsKey(file)) itemId: file,
          },
        });
    }
  }
}

final class _TusUpload {
  _TusUpload(this.length, this.contentType, this.expires);

  final int length;
  final String? contentType;
  final DateTime expires;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  String? fileId;

  int get offset => bytes.length;
}
