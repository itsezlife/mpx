import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http_bytes_cache/http_bytes_cache.dart' show HttpBytesResponse;
import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// An [UploadTransport] for a remote end that takes a file in one request:
/// a `multipart/form-data` body holding the host's form fields and the
/// file.
///
/// The file goes whole, as one part ([UploadCapabilities.partSize] is the
/// file's size), so the engine sends one request and tries it again when
/// it fails as any part is. Nothing resumes: an upload interrupted by a
/// restart starts again from the file's first byte. The remote end makes
/// its own thumbnail.
///
/// For each upload the host's [request] says where it goes: the URL, the
/// headers, the form fields and the file's field. [remoteRef] reads the
/// remote end's answer into the [RemoteRef] the upload completes with.
final class MultipartUploadTransport implements UploadTransport {
  /// A multipart transport sending each upload as [request] describes it
  /// and reading its answer with [remoteRef].
  ///
  /// [reuse] judges a stored reference (by default
  /// [defaultReuse]); [id] names the transport in the journal.
  MultipartUploadTransport({
    required this.request,
    required this.remoteRef,
    this.id = 'multipart',
    UploadReuse reuse = defaultReuse,
    math.Random? random,
  }) : capabilities = UploadCapabilities(partSize: _wholeFile, reuse: reuse),
       _random = random ?? math.Random.secure();

  /// How long a stored reference of this transport is good by default: a
  /// day after it was stored, the journal's retention. The transport knows
  /// nothing of how long the remote end keeps its files, so the default
  /// covers sending the same media again soon; a host whose server keeps
  /// them longer, or can be asked, passes its own [UploadReuse].
  static const UploadReuse defaultReuse = UploadReuse.lifetime(
    Duration(hours: 24),
  );

  /// Describes the request for an upload: called once per session, so a
  /// host may fetch a fresh URL or token for it. A throw fails the open,
  /// which the engine tries again as it judges the error.
  final FutureOr<MultipartUploadRequest> Function(UploadInfo info) request;

  /// Reads the remote end's successful answer into the reference the
  /// upload completes with. A throw fails the upload, without a try again
  /// (`unreadable_answer`).
  final RemoteRef Function(HttpBytesResponse response) remoteRef;

  @override
  final String id;

  @override
  final UploadCapabilities capabilities;

  final math.Random _random;

  static int _wholeFile(int size) => math.max(size, 1);

  @override
  Future<UploadSession> open(UploadInfo info, {String? resumeToken}) async =>
      _MultipartSession(info, await request(info), remoteRef, _boundary);

  /// A boundary no file is expected to hold: 32 random hex digits, drawn
  /// again for each request.
  String _boundary() {
    final digits = StringBuffer('mpx-');
    for (var i = 0; i < 32; i++) {
      digits.write(_random.nextInt(16).toRadixString(16));
    }
    return digits.toString();
  }
}

/// Where one upload of a [MultipartUploadTransport] goes, and what its form
/// holds besides the file.
@immutable
final class MultipartUploadRequest {
  /// A `POST` to [url] with [headers], whose form holds [fields] and then
  /// the file under [fileField].
  ///
  /// [fileName] and [contentType] name the file in its part; null takes
  /// the upload's own (`UploadInfo.fileName`, `UploadInfo.contentType`),
  /// and without those `file` and `application/octet-stream`.
  const MultipartUploadRequest(
    this.url, {
    this.method = 'POST',
    this.headers = const {},
    this.fields = const {},
    this.fileField = 'file',
    this.fileName,
    this.contentType,
  });

  /// Where the form is sent.
  final Uri url;

  /// The request's method: `POST`, or `PUT` / `PATCH` for a remote end
  /// that takes a form so.
  final String method;

  /// The request's headers; the transport sets `Content-Type` itself.
  final Map<String, String> headers;

  /// The form's text fields, sent before the file in this order.
  final Map<String, String> fields;

  /// The form field that holds the file.
  final String fileField;

  /// The file's name in its part; null for the upload's.
  final String? fileName;

  /// The file's media type in its part; null for the upload's.
  final String? contentType;
}

final class _MultipartSession implements UploadSession {
  _MultipartSession(this._info, this._request, this._remoteRef, this._boundary);

  final UploadInfo _info;
  final MultipartUploadRequest _request;
  final RemoteRef Function(HttpBytesResponse response) _remoteRef;
  final String Function() _boundary;

  @override
  String? get resumeToken => null;

  @override
  bool get resumed => false;

  @override
  DateTime? get resumeExpiresAt => null;

  @override
  Future<UploadPartAck> sendPart(
    int index,
    int offset,
    UploadPartBody bytes, {
    required bool last,
  }) async {
    if (index != 0 || offset != 0 || !last) {
      throw const UploadTransportException(
        'unexpected_part',
        kind: TransferFailureKind.local,
        message: 'A multipart upload sends the whole file as part 0.',
      );
    }
    final boundary = _boundary();
    final response = await bytes.send(
      _request.url,
      method: _request.method,
      headers: {
        ..._request.headers,
        'content-type': 'multipart/form-data; boundary=$boundary',
      },
      prefix: _prefix(boundary),
      suffix: utf8.encode('\r\n--$boundary--\r\n'),
    );
    final RemoteRef ref;
    try {
      ref = _remoteRef(response);
    } on Object catch (error) {
      throw UploadTransportException('unreadable_answer', message: '$error');
    }
    // The reference rides in the receipt, so finish needs nothing the
    // journal does not keep.
    return UploadPartAck(receipt: jsonEncode(RemoteRef.codec.encode(ref)));
  }

  @override
  Future<RemoteRef> finish(int finalSize, List<UploadPartAck> parts) async {
    final receipt = parts.length == 1 ? parts.single.receipt : null;
    if (receipt == null) {
      throw const UploadTransportException(
        'missing_answer',
        kind: TransferFailureKind.local,
        message: 'finish needs the one part acknowledged with its answer.',
      );
    }
    return RemoteRef.codec.decode(jsonDecode(receipt) as Map<String, Object?>)
        as RemoteRef;
  }

  List<int> _prefix(String boundary) {
    final form = StringBuffer();
    for (final MapEntry(:key, :value) in _request.fields.entries) {
      form
        ..write('--$boundary\r\n')
        ..write('Content-Disposition: form-data; name="${_quoted(key)}"')
        ..write('\r\n\r\n')
        ..write(value)
        ..write('\r\n');
    }
    final fileName = _request.fileName ?? _info.fileName ?? 'file';
    final contentType =
        _request.contentType ?? _info.contentType ?? 'application/octet-stream';
    form
      ..write('--$boundary\r\n')
      ..write(
        'Content-Disposition: form-data; '
        'name="${_quoted(_request.fileField)}"; '
        'filename="${_quoted(fileName)}"\r\n',
      )
      ..write('Content-Type: $contentType\r\n\r\n');
    return utf8.encode(form.toString());
  }

  /// A name inside a quoted header parameter, escaped as browsers send it:
  /// a quote and a line break percent-encoded.
  static String _quoted(String name) => name
      .replaceAll('"', '%22')
      .replaceAll('\r', '%0D')
      .replaceAll('\n', '%0A');
}
