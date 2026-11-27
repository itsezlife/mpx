import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'upload_test_server.dart';

/// One upload a [TusServer] holds.
final class TusServerUpload {
  TusServerUpload(this.path, this.length, this.metadata, this.expiresAt);

  /// The upload's path on the server, as its `Location` named it.
  final String path;

  /// The declared `Upload-Length`.
  final int length;

  /// The decoded `Upload-Metadata`.
  final Map<String, String> metadata;

  /// What `Upload-Expires` answers; null for none.
  DateTime? expiresAt;

  /// The bytes the server holds, from the start.
  final BytesBuilder bytes = BytesBuilder(copy: false);

  /// The server's offset.
  int get offset => bytes.length;
}

/// One `PATCH` the server took in.
final class TusServerPatch {
  TusServerPatch(this.path, this.offset);

  /// The upload's path.
  final String path;

  /// The `Upload-Offset` the request carried.
  final int offset;

  /// The body bytes the server kept from it.
  int received = 0;
}

/// The tus resumable upload protocol (core, creation and expiration),
/// mounted on an [UploadTestServer]: uploads kept in memory, with knobs a
/// test turns to break a request off, forget an upload or expire it.
final class TusProtocol {
  /// Mounts the protocol at [path] of [server].
  TusProtocol(this.server, {this.path = '/tus/'}) {
    server.mountStreaming(path, _handle);
  }

  /// The protocol version the server speaks.
  static const String version = '1.0.0';

  final UploadTestServer server;

  /// The creation path; uploads live below it.
  final String path;

  int _next = 0;

  /// The uploads by path.
  final Map<String, TusServerUpload> uploads = {};

  /// Every request's method and path, in arrival order.
  final List<String> requests = [];

  /// Every `PATCH`, in arrival order.
  final List<TusServerPatch> patches = [];

  /// The `Upload-Expires` a new upload is given; null for none.
  DateTime? Function() expiresAt = () => null;

  /// Statuses answered to the next `PATCH`es instead of taking them, one
  /// per request.
  final List<int> patchStatuses = [];

  /// When set, the next `PATCH` stops reading once its upload holds this
  /// many bytes, and the connection drops once [release] completes; the
  /// server keeps exactly those bytes, as a tus server keeps a broken-off
  /// body.
  int? breakAt;

  /// Completes when a `PATCH` reached [breakAt].
  Completer<void> broke = Completer<void>();

  /// Lets a `PATCH` held at [breakAt] drop.
  Completer<void> release = Completer<void>();

  /// Paths answered with a status (404 or 410) as an upload forgotten.
  final Map<String, int> forgotten = {};

  /// The creation endpoint.
  Uri get endpoint => server.url(path);

  /// The upload at [url], or null.
  TusServerUpload? uploadAt(String url) => uploads[Uri.parse(url).path];

  /// Forgets the upload at [url]: its `HEAD` and `PATCH` answer [status].
  void forget(String url, {int status = 404}) {
    final path = Uri.parse(url).path;
    uploads.remove(path);
    forgotten[path] = status;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    final response = request.response;
    if (request.headers.value('tus-resumable') != version) {
      await request.drain<void>();
      response
        ..statusCode = 412
        ..headers.set('tus-version', version);
      return response.close();
    }
    response.headers.set('tus-resumable', version);
    switch (request.method) {
      case 'POST' when path == this.path:
        return _create(request);
      case 'HEAD':
        return _head(request, path);
      case 'PATCH':
        return _patch(request, path);
      default:
        await request.drain<void>();
        response.statusCode = 405;
        return response.close();
    }
  }

  Future<void> _create(HttpRequest request) async {
    await request.drain<void>();
    final response = request.response;
    final length = int.tryParse(request.headers.value('upload-length') ?? '');
    if (length == null || length < 0) {
      response.statusCode = 400;
      return response.close();
    }
    final metadata = <String, String>{};
    for (final pair in (request.headers.value('upload-metadata') ?? '').split(
      ',',
    )) {
      final parts = pair.trim().split(' ');
      if (parts.first.isEmpty) continue;
      metadata[parts.first] = parts.length > 1
          ? utf8.decode(base64.decode(parts[1]))
          : '';
    }
    final path = '${this.path}${++_next}';
    final upload = uploads[path] = TusServerUpload(
      path,
      length,
      metadata,
      expiresAt(),
    );
    response
      ..statusCode = 201
      // Relative, as servers often answer: the client resolves it.
      ..headers.set('location', path);
    _expires(response, upload);
    return response.close();
  }

  Future<void> _head(HttpRequest request, String path) async {
    await request.drain<void>();
    final response = request.response..headers.set('cache-control', 'no-store');
    final upload = uploads[path];
    if (upload == null) {
      response.statusCode = forgotten[path] ?? 404;
      return response.close();
    }
    response
      ..statusCode = 200
      ..headers.set('upload-offset', '${upload.offset}')
      ..headers.set('upload-length', '${upload.length}');
    _expires(response, upload);
    return response.close();
  }

  Future<void> _patch(HttpRequest request, String path) async {
    final response = request.response;
    final upload = uploads[path];
    final offset = int.tryParse(request.headers.value('upload-offset') ?? '');
    if (upload == null) {
      await request.drain<void>();
      response.statusCode = forgotten[path] ?? 404;
      return response.close();
    }
    if (request.headers.contentType?.mimeType !=
        'application/offset+octet-stream') {
      await request.drain<void>();
      response.statusCode = 415;
      return response.close();
    }
    if (patchStatuses.isNotEmpty) {
      await request.drain<void>();
      response.statusCode = patchStatuses.removeAt(0);
      return response.close();
    }
    if (offset != upload.offset) {
      await request.drain<void>();
      response.statusCode = 409;
      return response.close();
    }
    final patch = TusServerPatch(path, offset!);
    patches.add(patch);
    final breakAt = this.breakAt;
    await for (final chunk in request) {
      final room =
          (breakAt == null ? upload.length : math.min(breakAt, upload.length)) -
          upload.offset;
      final kept = chunk.length > room ? chunk.sublist(0, room) : chunk;
      upload.bytes.add(kept);
      patch.received += kept.length;
      if (breakAt != null && upload.offset >= breakAt) {
        this.breakAt = null;
        broke.complete();
        await release.future;
        final socket = await response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
    }
    response
      ..statusCode = 204
      ..headers.set('upload-offset', '${upload.offset}');
    _expires(response, upload);
    return response.close();
  }

  void _expires(HttpResponse response, TusServerUpload upload) {
    final expiresAt = upload.expiresAt;
    if (expiresAt != null) {
      response.headers.set('upload-expires', HttpDate.format(expiresAt));
    }
  }
}
