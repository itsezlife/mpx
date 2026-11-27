import 'dart:convert';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_parser/http_parser.dart' show parseHttpDate;
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_lane.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// Where a completed tus upload lives, as the host names it: from the
/// upload's URL and the headers of the server's last answer.
typedef TusRemoteRef =
    RemoteRef Function(Uri upload, Map<String, String> headers);

/// An [UploadTransport] for a server of the tus resumable upload protocol,
/// version 1.0.0: the core protocol with the creation and expiration
/// extensions.
///
/// - **Create.** A new upload is a `POST` to [endpoint] with its
///   `Upload-Length` and `Upload-Metadata` (the file's name and type, and
///   [metadata]); the answer's `Location` is the upload's URL, which is the
///   session's resume token.
/// - **Parts.** Each part is a `PATCH` to the upload's URL at the server's
///   `Upload-Offset`, one at a time: the protocol has no parallel parts
///   (that needs the concatenation extension, not spoken here). After a try
///   that failed the session asks the server's offset again (`HEAD`) and
///   sends only the part's bytes the server does not hold.
/// - **Resume.** Reopening with a token asks the server's offset (`HEAD`);
///   the session is an [UploadOffsetSession], so the engine sends only what
///   the server lacks, whatever its journal kept. An upload the server
///   forgot (`404`, `410`), whose `Upload-Expires` passed, or whose length
///   is not the file's, starts again from zero: a new upload, not a
///   failure.
/// - **Finish.** The upload is complete once the server's offset is the
///   file's size; the reference is the upload's URL unless [remoteRef]
///   names it otherwise.
///
/// Every request goes through [client] with [headers] and [context], so the
/// host's middlewares (a Bearer header) reach them; the parts through the
/// engine's client, which the host makes the same one. Diagnostics are the
/// engine's (`TransportOp`), with this transport's [id].
final class TusUploadTransport implements UploadTransport {
  /// A transport creating its uploads at [endpoint] through [client].
  ///
  /// [partSize] defaults to [defaultPartSize]. [now] is the clock an
  /// `Upload-Expires` is read against.
  TusUploadTransport({
    required this.endpoint,
    required HttpBytesClient client,
    this.id = 'tus',
    Map<String, String> headers = const {},
    Map<String, String> metadata = const {},
    Map<String, Object?>? context,
    UploadPartSize partSize = defaultPartSize,
    TusRemoteRef? remoteRef,
    DateTime Function() now = DateTime.now,
  }) : _client = client,
       _headers = Map.unmodifiable(headers),
       _metadata = Map.unmodifiable(metadata),
       _context = context,
       _partSize = partSize,
       _remoteRef = remoteRef,
       _now = now;

  /// The protocol version every request names (`Tus-Resumable`).
  static const String version = '1.0.0';

  /// The attribute of every [RemoteRef] this transport answers that holds
  /// the upload's URL, which the reuse check asks again.
  static const String uploadUrlAttribute = 'tus.upload';

  /// 1 MiB parts for a file of the small lane, 4 MiB above it: few enough
  /// requests for a big file, and a kill loses at most one part's bytes of
  /// a progress window, since the server keeps its offset.
  static int defaultPartSize(int size) =>
      size > UploadLane.defaultSplit ? 4 * 1024 * 1024 : 1024 * 1024;

  /// Where new uploads are created.
  final Uri endpoint;

  @override
  final String id;

  final HttpBytesClient _client;
  final Map<String, String> _headers;
  final Map<String, String> _metadata;
  final Map<String, Object?>? _context;
  final UploadPartSize _partSize;
  final TusRemoteRef? _remoteRef;
  final DateTime Function() _now;

  /// Sequential parts, resume until the server's `Upload-Expires`, a known
  /// size, no thumbnail. A stored reference is judged by asking the server
  /// whether it still holds the whole upload ([UploadReuse.validity]):
  /// tus servers keep completed uploads by their own policy, which no fixed
  /// lifetime here could know.
  @override
  late final UploadCapabilities capabilities = UploadCapabilities(
    partSize: _partSize,
    resume: const UploadResume.serverExpiry(),
    reuse: UploadReuse.validity(_holds),
  );

  @override
  Future<UploadSession> open(UploadInfo info, {String? resumeToken}) async {
    if (resumeToken != null) {
      final reopened = await _reopen(Uri.parse(resumeToken), info.size);
      if (reopened != null) return reopened;
    }
    return _create(info);
  }

  // --- Requests --------------------------------------------------------------

  Map<String, String> _headersWith([Map<String, String> more = const {}]) => {
    ..._headers,
    'tus-resumable': version,
    ...more,
  };

  /// A `HEAD` of [upload] whose every status answers: the caller reads it.
  Future<HttpBytesResponse> _head(Uri upload) => _client.request(
    upload,
    method: 'HEAD',
    headers: _headersWith(const {'cache-control': 'no-store'}),
    context: {...?_context, HttpBytesContext.validateStatusKey: _anyStatus},
  );

  Future<_TusSession> _create(UploadInfo info) async {
    final metadata = {
      'filename': ?info.fileName,
      'filetype': ?info.contentType,
      ..._metadata,
    };
    final response = await _client.request(
      endpoint,
      method: 'POST',
      headers: _headersWith({
        'upload-length': '${info.size}',
        if (metadata.isNotEmpty)
          'upload-metadata': [
            for (final MapEntry(:key, :value) in metadata.entries)
              '$key ${base64.encode(utf8.encode(value))}',
          ].join(','),
      }),
      context: _context,
    );
    final location = response.headers['location'];
    if (location == null || location.isEmpty) {
      throw const UploadTransportException(
        'no_location',
        message: 'The creation answer named no upload URL.',
      );
    }
    return _TusSession(
      this,
      endpoint.resolve(location),
      size: info.size,
      offset: 0,
      resumed: false,
      expiresAt: _expiresOf(response.headers),
    );
  }

  /// The session continuing the upload at [upload], or null when the server
  /// no longer holds it as an upload of [size] bytes it keeps.
  Future<_TusSession?> _reopen(Uri upload, int size) async {
    final response = await _head(upload);
    final status = response.statusCode;
    if (status == 404 || status == 410) return null;
    if (status < 200 || status >= 300) throw _refused(status, 'resume_status');
    final offset = _intOf(response.headers['upload-offset']);
    final length = _intOf(response.headers['upload-length']);
    final expiresAt = _expiresOf(response.headers);
    if (offset == null ||
        offset > size ||
        (length != null && length != size) ||
        (expiresAt != null && !expiresAt.isAfter(_now()))) {
      return null;
    }
    return _TusSession(
      this,
      upload,
      size: size,
      offset: offset,
      resumed: true,
      expiresAt: expiresAt,
    );
  }

  /// Whether the server still holds the whole upload [ref] names. A server
  /// that cannot be reached, or refuses, counts as not holding it: the
  /// media goes again rather than as a reference that may be dead.
  Future<bool> _holds(RemoteRef ref) async {
    final upload = Uri.tryParse(ref.attributes[uploadUrlAttribute] ?? ref.id);
    if (upload == null) return false;
    final HttpBytesResponse response;
    try {
      response = await _head(upload);
    } on HttpBytesException {
      return false;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) return false;
    final offset = _intOf(response.headers['upload-offset']);
    final length = _intOf(response.headers['upload-length']);
    final expiresAt = _expiresOf(response.headers);
    return offset != null &&
        offset == length &&
        (expiresAt == null || expiresAt.isAfter(_now()));
  }

  RemoteRef _refOf(Uri upload, Map<String, String> headers) {
    final ref =
        _remoteRef?.call(upload, headers) ?? RemoteRef(upload.toString());
    return RemoteRef(
      ref.id,
      attributes: {...ref.attributes, uploadUrlAttribute: upload.toString()},
    );
  }

  static bool _anyStatus(int status) => true;

  static int? _intOf(String? value) =>
      value == null ? null : int.tryParse(value.trim());

  /// The `Upload-Expires` of an answer; null when it gave none, or none
  /// that reads as an HTTP date.
  static DateTime? _expiresOf(Map<String, String> headers) {
    final value = headers['upload-expires'];
    if (value == null) return null;
    try {
      return parseHttpDate(value).toUtc();
    } on FormatException {
      return null;
    }
  }

  /// A status the protocol did not expect, judged as the bytes cache judges
  /// an upload's answer: 5xx, 429 and 408 may pass.
  static UploadTransportException _refused(int status, String code) =>
      UploadTransportException(
        code,
        status: status,
        transient:
            status >= 500 || status == 429 || status == 408 || status == 0,
      );
}

/// One tus upload, at [url]: the offset the server holds as this session
/// last learned it.
final class _TusSession implements UploadOffsetSession {
  _TusSession(
    this._transport,
    this.url, {
    required this.size,
    required int offset,
    required this.resumed,
    required DateTime? expiresAt,
  }) : remoteOffset = offset,
       _offset = offset,
       resumeExpiresAt = expiresAt;

  final TusUploadTransport _transport;

  /// The upload's URL.
  final Uri url;

  /// The file's size, the upload's `Upload-Length`.
  final int size;

  @override
  final bool resumed;

  @override
  final int remoteOffset;

  @override
  DateTime? resumeExpiresAt;

  /// The server's offset, while [_known].
  int _offset;

  /// Whether [_offset] is the server's: false after a `PATCH` that did not
  /// answer, which may have left any part of its body on the server.
  bool _known = true;

  Map<String, String> _lastHeaders = const {};

  @override
  String get resumeToken => url.toString();

  @override
  Future<UploadPartAck> sendPart(
    int index,
    int offset,
    UploadPartBody bytes, {
    required bool last,
  }) async {
    if (!_known) await _learnOffset();
    final from = _offset - offset;
    // The server holds the part already: sent before, or by a try that
    // broke off after its last byte landed.
    if (from >= bytes.length) return const UploadPartAck();
    if (from < 0) {
      // Parts go in order, so the server lacks bytes before this part: it
      // lost them. A retry of the job reopens at the server's offset.
      throw const UploadTransportException(
        'offset_behind',
        message: 'The server holds less than the parts before this one.',
      );
    }
    _known = false;
    final HttpBytesResponse response;
    try {
      response = await bytes.send(
        url,
        method: 'PATCH',
        headers: _transport._headersWith({
          'upload-offset': '$_offset',
          'content-type': 'application/offset+octet-stream',
        }),
        context: _transport._context,
        from: from,
      );
    } on HttpBytesException catch (error) {
      throw _partFailure(error) ?? error;
    }
    _heard(response.headers);
    final reached = TusUploadTransport._intOf(
      response.headers['upload-offset'],
    );
    if (reached == null) {
      throw const UploadTransportException(
        'no_offset',
        transient: true,
        message: 'The PATCH answer named no Upload-Offset.',
      );
    }
    _offset = reached;
    _known = true;
    if (reached < offset + bytes.length) {
      throw const UploadTransportException(
        'short_write',
        transient: true,
        message: 'The server kept less than the part.',
      );
    }
    return const UploadPartAck();
  }

  @override
  Future<RemoteRef> finish(int finalSize, List<UploadPartAck> parts) async {
    if (!_known || _offset != finalSize) await _learnOffset();
    if (_offset != finalSize) {
      throw const UploadTransportException(
        'incomplete',
        message: 'The server does not hold the whole file.',
      );
    }
    return _transport._refOf(url, _lastHeaders);
  }

  /// Asks the server's offset.
  Future<void> _learnOffset() async {
    final response = await _transport._head(url);
    final status = response.statusCode;
    if (status == 404 || status == 410) throw _gone(status);
    if (status < 200 || status >= 300) {
      throw TusUploadTransport._refused(status, 'head_status');
    }
    final offset = TusUploadTransport._intOf(response.headers['upload-offset']);
    if (offset == null) {
      throw const UploadTransportException(
        'no_offset',
        transient: true,
        message: 'The HEAD answer named no Upload-Offset.',
      );
    }
    _heard(response.headers);
    _offset = offset;
    _known = true;
  }

  void _heard(Map<String, String> headers) {
    _lastHeaders = headers;
    resumeExpiresAt = TusUploadTransport._expiresOf(headers) ?? resumeExpiresAt;
  }

  /// What a refused `PATCH` means in the protocol; null for a failure the
  /// engine judges as any request's.
  static UploadTransportException? _partFailure(HttpBytesException error) =>
      switch (error.statusCode) {
        404 || 410 => _gone(error.statusCode),
        // The offset sent is not the server's: ask it, and try again.
        409 => const UploadTransportException(
          'offset_conflict',
          status: 409,
          transient: true,
        ),
        _ => null,
      };

  /// The server forgot the upload mid-session. Not tried again in this
  /// run; a retry of the job reopens, finds it gone and starts from zero.
  static UploadTransportException _gone(int status) => UploadTransportException(
    'upload_gone',
    status: status,
    message: 'The server no longer holds the upload.',
  );
}
