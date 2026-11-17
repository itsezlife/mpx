import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/http_bytes_cache.dart';

/// One request the stack sent.
final class NetRequest {
  NetRequest(this.url, this.range, this.started);

  final Uri url;

  /// The `range` header, or null for the whole body.
  final String? range;
  final Duration started;
  int? status;

  /// Request to response headers.
  Duration? firstByte;

  /// Request to the body's end; null while it streams or after a failure.
  Duration? done;
  int bytes = 0;
  bool failed = false;
}

/// An `http.Client` that forwards to [inner] and records every request:
/// its time to first byte, its download time and its bytes, for the run's
/// network numbers beside the frame metrics.
final class NetRecorder extends http.BaseClient {
  NetRecorder(this.inner);

  final http.Client inner;
  final Stopwatch _clock = Stopwatch()..start();

  /// Every request since the start (or the last [clear]), in order.
  final List<NetRequest> requests = [];

  void clear() => requests.clear();

  /// Records a transfer the client's worker ran: its socket never passed
  /// through [send].
  void recordTransfer(HttpBytesTransferRecord transfer) {
    requests.add(
      NetRequest(transfer.url, transfer.range, _clock.elapsed - transfer.ended)
        ..status = transfer.statusCode == 0 ? null : transfer.statusCode
        ..firstByte = transfer.head
        ..done = transfer.failed ? null : transfer.ended
        ..bytes = transfer.bytes
        ..failed = transfer.failed,
    );
  }

  /// Hosts such as Wikimedia refuse requests without a descriptive agent.
  static const String userAgent = 'mpx-example-lab/1.0 (media performance lab)';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers.putIfAbsent('user-agent', () => userAgent);
    final record = NetRequest(
      request.url,
      request.headers['range'] ?? request.headers['Range'],
      _clock.elapsed,
    );
    requests.add(record);
    final http.StreamedResponse response;
    try {
      response = await inner.send(request);
    } on Object {
      record.failed = true;
      rethrow;
    }
    record
      ..status = response.statusCode
      ..firstByte = _clock.elapsed - record.started;
    final body = response.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          record.bytes += chunk.length;
          sink.add(chunk);
        },
        handleError: (error, stack, sink) {
          record.failed = true;
          sink.addError(error, stack);
        },
        handleDone: (sink) {
          record.done = _clock.elapsed - record.started;
          sink.close();
        },
      ),
    );
    return http.StreamedResponse(
      body,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// The run's network numbers: a summary line, then a line per file.
  List<String> report({required int entries}) {
    String ms(Duration? d) => d == null ? '-' : '${d.inMilliseconds}';
    int p(List<int> sorted, double q) =>
        sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * q).round()];
    final ttfb = [
      for (final r in requests)
        if (r.firstByte case final d?) d.inMilliseconds,
    ]..sort();
    final download = [
      for (final r in requests)
        if (r.done case final d?) d.inMilliseconds,
    ]..sort();
    final byFile = <String, List<NetRequest>>{};
    for (final r in requests) {
      (byFile[r.url.pathSegments.lastOrNull ?? '${r.url}'] ??= []).add(r);
    }
    final bytes = requests.fold(0, (sum, r) => sum + r.bytes);
    return [
      'net requests=${requests.length} '
          'failed=${requests.where((r) => r.failed).length} '
          'bytes=$bytes '
          'ttfb p50/max=${p(ttfb, .5)}/${ttfb.lastOrNull ?? 0}ms '
          'download p50/max=${p(download, .5)}/${download.lastOrNull ?? 0}ms '
          'files=${byFile.length} of $entries entries '
          '(the rest came from the cache or were not shown)',
      for (final MapEntry(key: file, value: list) in byFile.entries)
        'net file $file host=${list.first.url.host} requests=${list.length} '
            'ranged=${list.where((r) => r.range != null).length} '
            'bytes=${list.fold(0, (sum, r) => sum + r.bytes)} '
            'ttfb=${ms(list.first.firstByte)}ms '
            'download=${ms(list.first.done)}ms '
            '${_span(list)}',
    ];
  }

  // A file fetched in several requests (parts, read-ahead) took from its
  // first request's start to its last request's end; its throughput is its
  // bytes over that span.
  static String _span(List<NetRequest> list) {
    final ends = [
      for (final r in list)
        if (r.done case final d?) r.started + d,
    ];
    if (ends.isEmpty) return 'span=- kbps=-';
    final start = list.map((r) => r.started).reduce((a, b) => a < b ? a : b);
    final end = ends.reduce((a, b) => a > b ? a : b);
    final span = end - start;
    final bytes = list.fold(0, (sum, r) => sum + r.bytes);
    final kbps = span.inMicroseconds == 0
        ? 0
        : bytes * 8 * 1000 ~/ span.inMicroseconds;
    return 'span=${span.inMilliseconds}ms kbps=$kbps';
  }

  @override
  void close() => inner.close();
}
