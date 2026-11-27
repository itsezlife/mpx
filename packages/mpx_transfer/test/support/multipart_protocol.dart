import 'dart:convert';
import 'dart:typed_data';

import 'upload_test_server.dart';

/// One form the multipart protocol took: its text fields and its file
/// part.
final class ReceivedForm {
  ReceivedForm(this.fields, this.fileField, this.fileName, this.contentType);

  final Map<String, String> fields;
  final String? fileField;
  final String? fileName;
  final String? contentType;
}

/// A `multipart/form-data` endpoint: keeps the form's file in
/// [UploadTestServer.files] and answers `{"id": ..., "size": ...}`.
final class MultipartProtocol {
  /// Mounts the protocol at [path] of [server].
  MultipartProtocol(this.server, {this.path = '/multipart'}) {
    server.mount(path, _answer);
  }

  final UploadTestServer server;
  final String path;

  /// The forms taken, in arrival order.
  final List<ReceivedForm> forms = [];

  Uri get url => server.url(path);

  TestAnswer _answer(ReceivedRequest request) {
    final type = request.headers['content-type'] ?? '';
    final match = RegExp('boundary=(.+)').firstMatch(type);
    if (!type.startsWith('multipart/form-data') || match == null) {
      return const TestAnswer(415);
    }
    final parts = _split(request.body, match.group(1)!);
    if (parts == null) return const TestAnswer(400);
    final fields = <String, String>{};
    String? fileField;
    String? fileName;
    String? contentType;
    Uint8List? file;
    for (final (:headers, :body) in parts) {
      final disposition = headers['content-disposition'] ?? '';
      final name = RegExp('name="([^"]*)"').firstMatch(disposition)?.group(1);
      final filename = RegExp(
        'filename="([^"]*)"',
      ).firstMatch(disposition)?.group(1);
      if (name == null) return const TestAnswer(400);
      if (filename == null) {
        fields[name] = utf8.decode(body);
      } else {
        fileField = name;
        fileName = filename;
        contentType = headers['content-type'];
        file = body;
      }
    }
    forms.add(ReceivedForm(fields, fileField, fileName, contentType));
    if (file == null) return const TestAnswer(400);
    final id = server.nextFileId();
    server.files[id] = file;
    return TestAnswer(
      200,
      headers: const {'content-type': 'application/json'},
      body: utf8.encode(jsonEncode({'id': id, 'size': file.length})),
    );
  }

  /// The parts between the boundaries, each its headers and body; null
  /// when the body is not a well-formed form.
  static List<({Map<String, String> headers, Uint8List body})>? _split(
    Uint8List body,
    String boundary,
  ) {
    final delimiter = utf8.encode('--$boundary');
    final starts = <int>[];
    for (var at = _find(body, delimiter, 0); at >= 0;) {
      starts.add(at);
      at = _find(body, delimiter, at + delimiter.length);
    }
    if (starts.length < 2) return null;
    final closing = starts.last + delimiter.length;
    if (body.length < closing + 2 ||
        body[closing] != 0x2d ||
        body[closing + 1] != 0x2d) {
      return null;
    }
    final parts = <({Map<String, String> headers, Uint8List body})>[];
    for (var i = 0; i < starts.length - 1; i++) {
      // After the delimiter, CRLF; before the next one, CRLF.
      final from = starts[i] + delimiter.length + 2;
      final to = starts[i + 1] - 2;
      final part = Uint8List.sublistView(body, from, to);
      final split = _find(part, const [13, 10, 13, 10], 0);
      if (split < 0) return null;
      final headers = <String, String>{};
      for (final line in utf8.decode(part.sublist(0, split)).split('\r\n')) {
        final colon = line.indexOf(':');
        if (colon < 0) return null;
        headers[line.substring(0, colon).trim().toLowerCase()] = line
            .substring(colon + 1)
            .trim();
      }
      parts.add((headers: headers, body: part.sublist(split + 4)));
    }
    return parts;
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
}
