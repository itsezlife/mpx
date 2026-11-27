import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

/// One part request a [NumberedPartsServer] took in.
final class ReceivedPart {
  ReceivedPart(this.protocol, this.uploadId, this.number, this.length);

  /// `numbered` or `presigned`.
  final String protocol;
  final String uploadId;
  final int number;
  final int length;

  @override
  String toString() => '$protocol $uploadId #$number ($length)';
}

/// A local HTTP server speaking two numbered-parts protocols, for adapter
/// tests:
///
/// - **numbered**, a host's own protocol: `POST /numbered/start` answers
///   `{"uploadId"}`; `PUT /numbered/<id>/<n>` takes part n and answers an
///   `x-part-id` header; `POST /numbered/<id>/complete` takes
///   `{"parts": [{"number", "id"}]}` and answers `{"file"}`; the file reads
///   back from `GET /numbered/files/<file>`.
/// - **presigned**, an imitation of S3 multipart with presigned parts:
///   `POST /bucket/<key>?uploads` answers the `UploadId` in XML;
///   `PUT /bucket/<key>?partNumber=n&uploadId=u&X-Amz-Signature=s` takes a part
///   signed by [sign] and answers its `ETag` (the part's MD5, quoted);
///   `POST /bucket/<key>?uploadId=u` takes the `CompleteMultipartUpload`
///   part list, checks it as the store does (order, ETags, parts but the
///   last of at least [minPartSize]) and answers in XML; the object reads
///   back from `GET /bucket/<key>`.
///
/// [failParts] answers part requests with an error status first; [holdParts]
/// leaves part requests unanswered past a count until [releaseHeld].
final class NumberedPartsServer {
  NumberedPartsServer._(this._server, this.minPartSize);

  /// A server on a free loopback port; presigned parts but the last must
  /// hold at least [minPartSize] bytes.
  static Future<NumberedPartsServer> start({int minPartSize = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final parts = NumberedPartsServer._(server, minPartSize);
    server.listen(parts._handle);
    return parts;
  }

  final HttpServer _server;

  /// The presigned store's smallest part but the last.
  final int minPartSize;

  /// Every part request read to its end, in arrival order.
  final List<ReceivedPart> received = [];

  /// The uploads started, by protocol.
  int numberedStarts = 0;
  int presignedStarts = 0;

  /// The completions taken, each with its part numbers in order.
  final List<List<int>> completions = [];

  /// The most part requests on the wire at once.
  int maxConcurrentParts = 0;

  /// The part requests on the wire now.
  int get concurrentParts => _concurrentParts;
  int _concurrentParts = 0;

  final Map<String, Map<int, Uint8List>> _uploads = {};
  final Map<String, Map<int, String>> _receipts = {};
  final Map<String, Uint8List> _files = {};
  int _nextId = 0;

  final List<int> _failures = [];
  int? _holdAfter;
  Completer<void> _release = Completer<void>();
  int _partsTaken = 0;

  /// The base URL.
  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  /// The next [times] part requests fail with [status].
  void failParts(int times, {int status = 500}) {
    _failures.addAll(List.filled(times, status));
  }

  /// Part requests after the next [count] are read but left unanswered
  /// until [releaseHeld].
  void holdParts(int count) {
    _holdAfter = _partsTaken + count;
    _release = Completer<void>();
  }

  /// Answers the held part requests, and holds no more.
  void releaseHeld() {
    _holdAfter = null;
    if (!_release.isCompleted) _release.complete();
  }

  /// The signature a presigned part URL carries.
  static String sign(String key, String uploadId, int number) =>
      md5.convert(utf8.encode('secret:$key:$uploadId:$number')).toString();

  /// The bytes of numbered file [file] or presigned object [key].
  Uint8List? file(String name) => _files[name];

  Future<void> close() async {
    releaseHeld();
    await _server.close(force: true);
  }

  // --- Host side ------------------------------------------------------------

  /// A request as the host's own server code sends it: [method] [path]
  /// with [body]; answers the status and the body as text.
  Future<({int status, String body})> call(
    String method,
    String path, {
    String body = '',
  }) => HttpOverrides.runWithHttpOverrides(
    () => _call(method, path, body: body),
    _RealHttp(),
  );

  Future<({int status, String body})> _call(
    String method,
    String path, {
    required String body,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, base.resolve(path));
      request.write(body);
      final response = await request.close();
      return (
        status: response.statusCode,
        body: await response.transform(utf8.decoder).join(),
      );
    } finally {
      client.close();
    }
  }

  // --- Server side ----------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    try {
      if (segments.isNotEmpty && segments.first == 'numbered') {
        await _numbered(request, segments.sublist(1));
      } else if (segments.isNotEmpty && segments.first == 'bucket') {
        await _presigned(request, segments.sublist(1).join('/'));
      } else {
        await _answer(request, 404);
      }
    } on Object {
      await _answer(request, 500);
    }
  }

  Future<void> _numbered(HttpRequest request, List<String> path) async {
    switch ((request.method, path)) {
      case ('POST', ['start']):
        await _drain(request);
        numberedStarts++;
        final id = 'n${_nextId++}';
        _uploads[id] = {};
        _receipts[id] = {};
        return _answer(request, 200, body: jsonEncode({'uploadId': id}));
      case ('PUT', [final id, final number]):
        final receipt = await _part(request, 'numbered', id, int.parse(number));
        if (receipt == null) return;
        request.response.headers.set('x-part-id', receipt);
        return _answer(request, 200);
      case ('POST', [final id, 'complete']):
        final json =
            jsonDecode(await utf8.decodeStream(request))
                as Map<String, Object?>;
        final listed = [
          for (final part
              in (json['parts']! as List<Object?>).cast<Map<String, Object?>>())
            (number: part['number']! as int, receipt: part['id'] as String?),
        ];
        final file = _assemble(id, listed, minPart: 0);
        if (file == null) return _answer(request, 400);
        _files['f-$id'] = file;
        return _answer(request, 200, body: jsonEncode({'file': 'f-$id'}));
      case ('GET', ['files', final name]):
        final file = _files[name];
        if (file == null) return _answer(request, 404);
        request.response.add(file);
        return _answer(request, 200);
    }
    await _drain(request);
    await _answer(request, 404);
  }

  Future<void> _presigned(HttpRequest request, String key) async {
    final query = request.uri.queryParameters;
    final uploadId = query['uploadId'];
    if (request.method == 'POST' && query.containsKey('uploads')) {
      await _drain(request);
      presignedStarts++;
      final id = 'p${_nextId++}';
      _uploads[id] = {};
      _receipts[id] = {};
      return _answer(
        request,
        200,
        body:
            '<InitiateMultipartUploadResult><Key>$key</Key>'
            '<UploadId>$id</UploadId></InitiateMultipartUploadResult>',
      );
    }
    if (request.method == 'PUT' && uploadId != null) {
      final number = int.parse(query['partNumber']!);
      if (query['X-Amz-Signature'] != sign(key, uploadId, number)) {
        await _drain(request);
        return _answer(request, 403, body: '<Error>SignatureDoesNotMatch');
      }
      final receipt = await _part(request, 'presigned', uploadId, number);
      if (receipt == null) return;
      request.response.headers.set('ETag', receipt);
      return _answer(request, 200);
    }
    if (request.method == 'POST' && uploadId != null) {
      final xml = await utf8.decodeStream(request);
      final listed = [
        for (final match in RegExp(
          r'<Part><PartNumber>(\d+)</PartNumber><ETag>([^<]*)</ETag></Part>',
        ).allMatches(xml))
          (
            number: int.parse(match.group(1)!),
            receipt: _unescape(match.group(2)!),
          ),
      ];
      final file = _assemble(uploadId, listed, minPart: minPartSize);
      if (file == null)
        return _answer(request, 400, body: '<Error>InvalidPart');
      _files[key] = file;
      return _answer(
        request,
        200,
        body:
            '<CompleteMultipartUploadResult><Key>$key</Key>'
            '</CompleteMultipartUploadResult>',
      );
    }
    if (request.method == 'GET') {
      final file = _files[key];
      if (file == null) return _answer(request, 404);
      request.response.add(file);
      return _answer(request, 200);
    }
    await _drain(request);
    await _answer(request, 404);
  }

  /// Takes a part's bytes; answers its receipt, or null once it answered
  /// an error itself.
  Future<String?> _part(
    HttpRequest request,
    String protocol,
    String uploadId,
    int number,
  ) async {
    _concurrentParts++;
    if (_concurrentParts > maxConcurrentParts) {
      maxConcurrentParts = _concurrentParts;
    }
    try {
      final bytes = BytesBuilder(copy: false);
      await request.forEach(bytes.add);
      final body = bytes.takeBytes();
      final parts = _uploads[uploadId];
      if (parts == null) {
        await _answer(request, 404);
        return null;
      }
      if (_failures.isNotEmpty) {
        await _answer(request, _failures.removeAt(0));
        return null;
      }
      final taken = _partsTaken++;
      if (_holdAfter case final holdAfter? when taken >= holdAfter) {
        await _release.future;
        // A held request whose client went away is not acknowledged.
      }
      received.add(ReceivedPart(protocol, uploadId, number, body.length));
      parts[number] = body;
      final receipt = protocol == 'presigned'
          ? '"${md5.convert(body)}"'
          : '$uploadId-$number-${md5.convert(body).toString().substring(0, 8)}';
      _receipts[uploadId]![number] = receipt;
      return receipt;
    } finally {
      _concurrentParts--;
    }
  }

  /// The file of upload [uploadId] from the [listed] parts, as a store
  /// checks them; null when the list is wrong.
  Uint8List? _assemble(
    String uploadId,
    List<({int number, String? receipt})> listed, {
    required int minPart,
  }) {
    final parts = _uploads[uploadId];
    final receipts = _receipts[uploadId];
    if (parts == null || receipts == null || listed.isEmpty) return null;
    final file = BytesBuilder(copy: false);
    for (var i = 0; i < listed.length; i++) {
      final (:number, :receipt) = listed[i];
      if (i > 0 && number <= listed[i - 1].number) return null;
      final bytes = parts[number];
      if (bytes == null || receipts[number] != receipt) return null;
      if (i < listed.length - 1 && bytes.length < minPart) return null;
      file.add(bytes);
    }
    completions.add([for (final part in listed) part.number]);
    _uploads.remove(uploadId);
    return file.takeBytes();
  }

  static String _unescape(String xml) => xml.replaceAll('&quot;', '"');

  static Future<void> _drain(HttpRequest request) => request.drain<void>();

  static Future<void> _answer(
    HttpRequest request,
    int status, {
    String? body,
  }) async {
    try {
      request.response.statusCode = status;
      if (body != null) request.response.write(body);
      await request.response.close();
    } on Object {
      // The client went away (a killed engine); nothing to answer.
    }
  }
}

/// The platform's own HTTP client, past the fake one a widget test's
/// binding installs for the whole process.
final class _RealHttp extends HttpOverrides {}

/// The host side of [NumberedPartsServer]'s numbered protocol, as a host
/// wires it into a [NumberedPartsTransport].
NumberedPartsTransport numberedTransport(
  NumberedPartsServer server, {
  int? smallPartSize,
  int? bigPartSize,
  int? bytesInFlight,
}) => NumberedPartsTransport(
  smallPartSize: smallPartSize ?? NumberedPartsTransport.defaultSmallPartSize,
  bigPartSize: bigPartSize ?? NumberedPartsTransport.defaultBigPartSize,
  bytesInFlight: bytesInFlight ?? NumberedPartsTransport.defaultBytesInFlight,
  start: (info) async {
    final answer = await server.call(
      'POST',
      '/numbered/start',
      body: jsonEncode({'size': info.size, 'parts': info.partCount}),
    );
    return (jsonDecode(answer.body) as Map<String, Object?>)['uploadId']!
        as String;
  },
  partRequest: (part) => NumberedPartRequest(
    server.base.resolve('/numbered/${part.uploadId}/${part.number}'),
  ),
  receiptOf: (response) => response.headers['x-part-id'],
  complete: (completion) async {
    final answer = await server.call(
      'POST',
      '/numbered/${completion.uploadId}/complete',
      body: jsonEncode({
        'parts': [
          for (final part in completion.parts)
            {'number': part.number, 'id': part.receipt},
        ],
      }),
    );
    if (answer.status != 200) {
      throw UploadTransportException('complete_refused', status: answer.status);
    }
    final file =
        (jsonDecode(answer.body) as Map<String, Object?>)['file']! as String;
    return RemoteRef(file);
  },
);

/// The host side of [NumberedPartsServer]'s presigned imitation: its
/// server creates the multipart upload of object [key], presigns each part
/// and completes with the part list.
NumberedPartsTransport presignedTransport(
  NumberedPartsServer server, {
  String key = 'media/object.bin',
  int? partSize,
  int? bytesInFlight,
}) => NumberedPartsTransport.presignedMultipart(
  partSize: partSize ?? NumberedPartsTransport.presignedPartSize,
  bytesInFlight: bytesInFlight ?? NumberedPartsTransport.presignedBytesInFlight,
  start: (info) async {
    final answer = await server.call('POST', '/bucket/$key?uploads');
    return RegExp(
      '<UploadId>([^<]+)</UploadId>',
    ).firstMatch(answer.body)!.group(1)!;
  },
  partRequest: (part) => NumberedPartRequest(
    server.base.replace(
      path: '/bucket/$key',
      queryParameters: {
        'partNumber': '${part.number}',
        'uploadId': part.uploadId,
        'X-Amz-Signature': NumberedPartsServer.sign(
          key,
          part.uploadId,
          part.number,
        ),
      },
    ),
  ),
  complete: (completion) async {
    final xml = StringBuffer('<CompleteMultipartUpload>');
    for (final part in completion.parts) {
      xml.write(
        '<Part><PartNumber>${part.number}</PartNumber>'
        '<ETag>${part.receipt!.replaceAll('"', '&quot;')}</ETag></Part>',
      );
    }
    xml.write('</CompleteMultipartUpload>');
    final answer = await server.call(
      'POST',
      '/bucket/$key?uploadId=${completion.uploadId}',
      body: xml.toString(),
    );
    if (answer.status != 200) {
      throw UploadTransportException('complete_refused', status: answer.status);
    }
    return RemoteRef(key);
  },
);
