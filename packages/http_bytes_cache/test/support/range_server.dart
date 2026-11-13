import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A local HTTP server for one body, with switchable range behaviour.
///
/// Serves [body] at any path. Range requests get `206` with `Content-Range`
/// unless [honourRanges] is off; `If-Range` that does not match [etag] gets
/// the full `200`. Every request is recorded in [requests].
final class RangeServer {
  RangeServer._(this._server, this.body);

  /// Starts on a free loopback port.
  static Future<RangeServer> start(Uint8List body) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final range = RangeServer._(server, body);
    server.listen(range._handle);
    return range;
  }

  final HttpServer _server;

  /// The representation served; replace it to model an origin change.
  Uint8List body;

  /// Strong `ETag` sent with every answer; null sends none.
  String? etag = '"v1"';

  /// Whether `Range` is answered with `206`.
  bool honourRanges = true;

  /// Whether `Accept-Ranges: bytes` is sent.
  bool advertiseRanges = true;

  /// When set, a request whose range starts here never gets an answer.
  int? stallAt;

  /// Received requests, in order.
  final List<RecordedRequest> requests = [];

  final List<HttpResponse> _stalled = [];

  /// Base URL of the served resource.
  Uri url([String path = '/video.mp4']) =>
      Uri.parse('http://${_server.address.host}:${_server.port}$path');

  /// Starts of every range requested, in order (null for a full GET).
  List<int?> get rangeStarts => [for (final r in requests) r.start];

  Future<void> close() async {
    for (final response in _stalled) {
      try {
        await response.close();
      } on Object {
        // Client already gone.
      }
    }
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final ifRange = request.headers.value('if-range');
    final parsed = _parseRange(rangeHeader);
    requests.add(
      RecordedRequest(
        start: parsed?.$1,
        end: parsed?.$2,
        ifRange: ifRange,
        ifNoneMatch: request.headers.value('if-none-match'),
      ),
    );
    final response = request.response;
    if (etag case final tag?) response.headers.set('etag', tag);
    if (advertiseRanges) response.headers.set('accept-ranges', 'bytes');

    if (parsed != null && stallAt == parsed.$1) {
      _stalled.add(response);
      return;
    }

    final total = body.length;
    final useRange =
        parsed != null && honourRanges && (ifRange == null || ifRange == etag);
    if (!useRange) {
      response
        ..statusCode = 200
        ..contentLength = total
        ..add(body);
      await response.close();
      return;
    }
    final (start, endInclusive) = parsed;
    if (start >= total) {
      response
        ..statusCode = 416
        ..headers.set('content-range', 'bytes */$total');
      await response.close();
      return;
    }
    final last = endInclusive == null || endInclusive >= total
        ? total - 1
        : endInclusive;
    response
      ..statusCode = 206
      ..headers.set('content-range', 'bytes $start-$last/$total')
      ..contentLength = last - start + 1
      ..add(Uint8List.sublistView(body, start, last + 1));
    await response.close();
  }

  static (int, int?)? _parseRange(String? header) {
    if (header == null) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final end = match.group(2)!;
    return (int.parse(match.group(1)!), end.isEmpty ? null : int.parse(end));
  }
}

/// One request [RangeServer] saw. [end] is inclusive, as on the wire.
final class RecordedRequest {
  RecordedRequest({this.start, this.end, this.ifRange, this.ifNoneMatch});

  final int? start;
  final int? end;
  final String? ifRange;
  final String? ifNoneMatch;
}

/// [length] bytes where byte i is `(i + seed) % 251` (a prime, so offsets
/// are easy to check and no window repeats at a power of two); another
/// [seed] gives another representation of the same length.
Uint8List patternBytes(int length, {int seed = 0}) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i + seed) % 251]);
