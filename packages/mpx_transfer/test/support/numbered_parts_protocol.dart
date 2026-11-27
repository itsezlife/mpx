import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

import 'upload_test_server.dart';

/// One part request the protocols took in.
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

/// Two numbered-parts protocols mounted on an [UploadTestServer]:
///
/// - **numbered**, a host's own protocol, under `/numbered`:
///   `POST /numbered/start` answers `{"uploadId"}`; `PUT /numbered/<id>/<n>`
///   takes part n and answers an `x-part-id` header;
///   `POST /numbered/<id>/complete` takes `{"parts": [{"number", "id"}]}`
///   and answers `{"file"}`, the file's id in [UploadTestServer.files].
/// - **presigned**, an imitation of S3 multipart with presigned parts,
///   under `/bucket`: `POST /bucket/<key>?uploads` answers the `UploadId`
///   in XML; `PUT /bucket/<key>?partNumber=n&uploadId=u&X-Amz-Signature=s`
///   takes a part signed by [sign] and answers its `ETag` (the part's MD5,
///   quoted); `POST /bucket/<key>?uploadId=u` takes the
///   `CompleteMultipartUpload` part list, checks it as the store does
///   (order, ETags, parts but the last of at least [minPartSize]) and
///   answers in XML; the object is kept in [UploadTestServer.files] by its
///   key.
///
/// [failParts] answers part requests with an error status first;
/// [holdParts] leaves part requests unanswered past a count until
/// [releaseHeld].
final class NumberedPartsProtocol {
  /// Mounts both protocols on [server]; presigned parts but the last must
  /// hold at least [minPartSize] bytes.
  NumberedPartsProtocol(this.server, {this.minPartSize = 0}) {
    server
      ..mount('/numbered/', _numbered)
      ..mount('/bucket/', _presigned);
  }

  final UploadTestServer server;

  /// The presigned store's smallest part but the last.
  final int minPartSize;

  /// Every part request taken, in arrival order.
  final List<ReceivedPart> received = [];

  /// The uploads started, by protocol.
  int numberedStarts = 0;
  int presignedStarts = 0;

  /// The completions taken, each with its part numbers in order.
  final List<List<int>> completions = [];

  /// The most part requests in hand at once.
  int maxConcurrentParts = 0;

  /// The part requests in hand now.
  int get concurrentParts => _concurrentParts;
  int _concurrentParts = 0;

  final Map<String, Map<int, Uint8List>> _uploads = {};
  final Map<String, Map<int, String>> _receipts = {};
  int _nextId = 0;

  final List<int> _failures = [];
  int? _holdAfter;
  Completer<void> _release = Completer<void>();
  int _partsTaken = 0;

  /// The next [times] part requests fail with [status].
  void failParts(int times, {int status = 500}) {
    _failures.addAll(List.filled(times, status));
  }

  /// Part requests after the next [count] are taken but left unanswered
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
      final request = await client.openUrl(method, server.url(path));
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

  Future<TestAnswer> _numbered(ReceivedRequest request) async {
    final path = request.uri.pathSegments.skip(1).toList();
    switch ((request.method, path)) {
      case ('POST', ['start']):
        numberedStarts++;
        final id = 'n${_nextId++}';
        _uploads[id] = {};
        _receipts[id] = {};
        return _text(200, jsonEncode({'uploadId': id}));
      case ('PUT', [final id, final number]):
        return _part(request, 'numbered', id, int.parse(number));
      case ('POST', [final id, 'complete']):
        final json =
            jsonDecode(utf8.decode(request.body)) as Map<String, Object?>;
        final listed = [
          for (final part
              in (json['parts']! as List<Object?>).cast<Map<String, Object?>>())
            (number: part['number']! as int, receipt: part['id'] as String?),
        ];
        final file = _assemble(id, listed, minPart: 0);
        if (file == null) return const TestAnswer(400);
        server.files['f-$id'] = file;
        return _text(200, jsonEncode({'file': 'f-$id'}));
    }
    return const TestAnswer(404);
  }

  Future<TestAnswer> _presigned(ReceivedRequest request) async {
    final key = request.uri.pathSegments.skip(1).join('/');
    final query = request.uri.queryParameters;
    final uploadId = query['uploadId'];
    if (request.method == 'POST' && query.containsKey('uploads')) {
      presignedStarts++;
      final id = 'p${_nextId++}';
      _uploads[id] = {};
      _receipts[id] = {};
      return _text(
        200,
        '<InitiateMultipartUploadResult><Key>$key</Key>'
        '<UploadId>$id</UploadId></InitiateMultipartUploadResult>',
      );
    }
    if (request.method == 'PUT' && uploadId != null) {
      final number = int.parse(query['partNumber']!);
      if (query['X-Amz-Signature'] != sign(key, uploadId, number)) {
        return _text(403, '<Error>SignatureDoesNotMatch</Error>');
      }
      return _part(request, 'presigned', uploadId, number);
    }
    if (request.method == 'POST' && uploadId != null) {
      final xml = utf8.decode(request.body);
      final listed = [
        for (final match in RegExp(
          r'<Part><PartNumber>(\d+)</PartNumber><ETag>([^<]*)</ETag></Part>',
        ).allMatches(xml))
          (
            number: int.parse(match.group(1)!),
            receipt: match.group(2)!.replaceAll('&quot;', '"'),
          ),
      ];
      final file = _assemble(uploadId, listed, minPart: minPartSize);
      if (file == null) return _text(400, '<Error>InvalidPart</Error>');
      server.files[key] = file;
      return _text(
        200,
        '<CompleteMultipartUploadResult><Key>$key</Key>'
        '</CompleteMultipartUploadResult>',
      );
    }
    return const TestAnswer(404);
  }

  /// Takes a part's bytes and answers its receipt in the protocol's
  /// header.
  Future<TestAnswer> _part(
    ReceivedRequest request,
    String protocol,
    String uploadId,
    int number,
  ) async {
    _concurrentParts++;
    if (_concurrentParts > maxConcurrentParts) {
      maxConcurrentParts = _concurrentParts;
    }
    try {
      final parts = _uploads[uploadId];
      if (parts == null) return const TestAnswer(404);
      if (_failures.isNotEmpty) return TestAnswer(_failures.removeAt(0));
      final taken = _partsTaken++;
      if (_holdAfter case final holdAfter? when taken >= holdAfter) {
        await _release.future;
      }
      final body = request.body;
      received.add(ReceivedPart(protocol, uploadId, number, body.length));
      parts[number] = body;
      final digest = md5.convert(body).toString();
      final receipt = protocol == 'presigned'
          ? '"$digest"'
          : '$uploadId-$number-${digest.substring(0, 8)}';
      _receipts[uploadId]![number] = receipt;
      return TestAnswer(
        200,
        headers: {protocol == 'presigned' ? 'ETag' : 'x-part-id': receipt},
      );
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

  static TestAnswer _text(int status, String body) =>
      TestAnswer(status, body: utf8.encode(body));
}

/// The platform's own HTTP client, past the fake one a widget test's
/// binding installs for the whole process.
final class _RealHttp extends HttpOverrides {}

/// The host side of [NumberedPartsProtocol]'s numbered protocol, as a host
/// wires it into a [NumberedPartsTransport].
NumberedPartsTransport numberedTransport(
  NumberedPartsProtocol protocol, {
  int? smallPartSize,
  int? bytesInFlight,
}) => NumberedPartsTransport(
  smallPartSize: smallPartSize ?? NumberedPartsTransport.defaultSmallPartSize,
  bytesInFlight: bytesInFlight ?? NumberedPartsTransport.defaultBytesInFlight,
  start: (info) async {
    final answer = await protocol.call(
      'POST',
      '/numbered/start',
      body: jsonEncode({'size': info.size, 'parts': info.partCount}),
    );
    return (jsonDecode(answer.body) as Map<String, Object?>)['uploadId']!
        as String;
  },
  partRequest: (part) => NumberedPartRequest(
    protocol.server.url('/numbered/${part.uploadId}/${part.number}'),
  ),
  receiptOf: (response) => response.headers['x-part-id'],
  complete: (completion) async {
    final answer = await protocol.call(
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

/// The host side of [NumberedPartsProtocol]'s presigned imitation: its
/// server picks an object key per upload, creates the multipart upload,
/// presigns each part and completes with the part list. The upload id it
/// answers holds the key and the store's upload id, as a host's would.
NumberedPartsTransport presignedTransport(
  NumberedPartsProtocol protocol, {
  int? partSize,
  int? bytesInFlight,
}) {
  var objects = 0;
  ({String key, String uploadId}) parse(String id) {
    final at = id.lastIndexOf('|');
    return (key: id.substring(0, at), uploadId: id.substring(at + 1));
  }

  return NumberedPartsTransport.presignedMultipart(
    partSize: partSize ?? NumberedPartsTransport.presignedPartSize,
    bytesInFlight:
        bytesInFlight ?? NumberedPartsTransport.presignedBytesInFlight,
    start: (info) async {
      final key = 'media/object-${++objects}.bin';
      final answer = await protocol.call('POST', '/bucket/$key?uploads');
      final uploadId = RegExp(
        '<UploadId>([^<]+)</UploadId>',
      ).firstMatch(answer.body)!.group(1)!;
      return '$key|$uploadId';
    },
    partRequest: (part) {
      final (:key, :uploadId) = parse(part.uploadId);
      return NumberedPartRequest(
        protocol.server
            .url('/bucket/$key')
            .replace(
              queryParameters: {
                'partNumber': '${part.number}',
                'uploadId': uploadId,
                'X-Amz-Signature': NumberedPartsProtocol.sign(
                  key,
                  uploadId,
                  part.number,
                ),
              },
            ),
      );
    },
    complete: (completion) async {
      final (:key, :uploadId) = parse(completion.uploadId);
      final xml = StringBuffer('<CompleteMultipartUpload>');
      for (final part in completion.parts) {
        xml.write(
          '<Part><PartNumber>${part.number}</PartNumber>'
          '<ETag>${part.receipt!.replaceAll('"', '&quot;')}</ETag></Part>',
        );
      }
      xml.write('</CompleteMultipartUpload>');
      final answer = await protocol.call(
        'POST',
        '/bucket/$key?uploadId=$uploadId',
        body: xml.toString(),
      );
      if (answer.status != 200) {
        throw UploadTransportException(
          'complete_refused',
          status: answer.status,
        );
      }
      return RemoteRef(key);
    },
  );
}
