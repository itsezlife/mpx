import 'dart:async';

import 'package:http_bytes_cache/http_bytes_cache.dart' show HttpBytesResponse;
import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_lane.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// Starts an upload on the remote end and answers its upload id: what
/// every part request and the completion name, and the token that reopens
/// the upload after a restart.
typedef NumberedPartsStart = Future<String> Function(UploadInfo info);

/// Answers where part [NumberedPart.number] goes: for presigned multipart,
/// the signed `PUT` the host's server issued for it.
typedef NumberedPartsRequest =
    FutureOr<NumberedPartRequest> Function(NumberedPart part);

/// Completes an upload once every part is acknowledged, with every part's
/// acknowledgement in order, and answers where the file now lives.
typedef NumberedPartsComplete =
    Future<RemoteRef> Function(NumberedPartsCompletion completion);

/// What the remote end acknowledged a part with, read from the answer to
/// its request: by default its `ETag` header.
typedef NumberedPartReceipt = String? Function(HttpBytesResponse response);

/// An [UploadTransport] for a remote end that takes a file in numbered
/// parts, in parallel: the host's own protocol, or S3, R2 and GCS presigned
/// multipart ([NumberedPartsTransport.presignedMultipart]).
///
/// The host speaks to its server through three calls, and the transport
/// sends the parts:
///
/// 1. [start] begins the upload and answers its upload id (for presigned
///    multipart, whatever the host's server needs to find the upload again:
///    the object key with the remote end's upload id). The id is the
///    session's resume token, so a restart within the freshness window
///    continues the same upload.
/// 2. [partRequest] answers the request for part N (numbered from 1): its
///    URL, method and headers. The transport sends the part's bytes there
///    and keeps what the answer acknowledged it with ([receiptOf]: the
///    `ETag` header by default).
/// 3. [complete] gets every part's number and acknowledgement in order and
///    answers the [RemoteRef].
///
/// A call that fails in a way a try again may mend throws an
/// [UploadTransportException] with `transient: true`, or the bytes cache's
/// `HttpBytesException`; anything else fails the upload without a retry.
///
/// Defaults: parts of [defaultSmallPartSize] (128 KiB), of
/// [defaultBigPartSize] (512 KiB) for a file over [defaultBigPartsAbove]
/// (10 MiB), larger parts once a file would need more than
/// [defaultMaxParts] (4000); [defaultBytesInFlight] (8 MiB) outstanding; a
/// resume window of [defaultSmallFileWindow] (1.5 h) for a file up to the
/// lane split, [defaultBigFileWindow] (24 h) above it; thumbnails sent as
/// uploads of their own; a stored reference good for [defaultReuse] (24 h).
final class NumberedPartsTransport implements UploadTransport {
  /// A transport over the host's [start], [partRequest] and [complete].
  NumberedPartsTransport({
    required this.start,
    required this.partRequest,
    required this.complete,
    this.id = 'numberedParts',
    this.smallPartSize = defaultSmallPartSize,
    this.bigPartSize = defaultBigPartSize,
    this.bigPartsAbove = defaultBigPartsAbove,
    this.maxParts = defaultMaxParts,
    this.bytesInFlight = defaultBytesInFlight,
    this.smallFileWindow = defaultSmallFileWindow,
    this.bigFileWindow = defaultBigFileWindow,
    this.windowSplit = UploadLane.defaultSplit,
    this.reuse = defaultReuse,
    this.receiptOf = etagOf,
  }) : assert(smallPartSize > 0, 'A part holds at least one byte.'),
       assert(bigPartSize > 0, 'A part holds at least one byte.'),
       assert(maxParts > 0, 'An upload has at least one part.');

  /// A transport for S3, R2 and GCS presigned multipart: [start] has the
  /// host's server create the multipart upload, [partRequest] answers the
  /// presigned `PUT` for the part, and [complete] has the server complete
  /// the upload with the part list, each part's number and `ETag`.
  ///
  /// These stores take parts of at least 5 MiB but the last and at most
  /// 10 000 of them, so parts are [presignedPartSize] (8 MiB) up to
  /// [presignedMaxParts] and [presignedBytesInFlight] (32 MiB, four parts)
  /// outstanding. On the web the bucket's CORS rules must expose the
  /// `ETag` header, or no part can be acknowledged.
  factory NumberedPartsTransport.presignedMultipart({
    required NumberedPartsStart start,
    required NumberedPartsRequest partRequest,
    required NumberedPartsComplete complete,
    String id = 'presignedMultipart',
    int partSize = presignedPartSize,
    int maxParts = presignedMaxParts,
    int bytesInFlight = presignedBytesInFlight,
    Duration smallFileWindow = defaultSmallFileWindow,
    Duration bigFileWindow = defaultBigFileWindow,
    int windowSplit = UploadLane.defaultSplit,
    UploadReuse reuse = defaultReuse,
  }) => NumberedPartsTransport(
    start: start,
    partRequest: partRequest,
    complete: complete,
    id: id,
    smallPartSize: partSize,
    bigPartSize: partSize,
    maxParts: maxParts,
    bytesInFlight: bytesInFlight,
    smallFileWindow: smallFileWindow,
    bigFileWindow: bigFileWindow,
    windowSplit: windowSplit,
    reuse: reuse,
  );

  /// The part size of a file up to [defaultBigPartsAbove]: 128 KiB.
  static const int defaultSmallPartSize = 128 * 1024;

  /// The part size of a file over [defaultBigPartsAbove]: 512 KiB.
  static const int defaultBigPartSize = 512 * 1024;

  /// The largest file sent in [defaultSmallPartSize] parts: 10 MiB.
  static const int defaultBigPartsAbove = 10 * 1024 * 1024;

  /// The most parts a file is split into before its parts grow: 4000.
  static const int defaultMaxParts = 4000;

  /// The bytes of parts outstanding at once: 8 MiB.
  static const int defaultBytesInFlight = 8 * 1024 * 1024;

  /// How long an interrupted upload of a file up to the window split
  /// reopens: 1.5 h.
  static const Duration defaultSmallFileWindow = Duration(minutes: 90);

  /// How long an interrupted upload of a file over the window split
  /// reopens: 24 h.
  static const Duration defaultBigFileWindow = Duration(hours: 24);

  /// How long a stored reference is good for sending the same media again:
  /// 24 h, as long as the remote end is known to keep an unfinished upload.
  /// A host whose store keeps files longer passes its own lifetime, or a
  /// validity call.
  static const UploadReuse defaultReuse = UploadReuse.lifetime(
    Duration(hours: 24),
  );

  /// The part size of [NumberedPartsTransport.presignedMultipart]: 8 MiB,
  /// over the stores' 5 MiB floor.
  static const int presignedPartSize = 8 * 1024 * 1024;

  /// The most parts of [NumberedPartsTransport.presignedMultipart]: the
  /// stores' 10 000.
  static const int presignedMaxParts = 10000;

  /// The bytes in flight of [NumberedPartsTransport.presignedMultipart]:
  /// 32 MiB, four parts.
  static const int presignedBytesInFlight = 32 * 1024 * 1024;

  /// Begins an upload; see the class.
  final NumberedPartsStart start;

  /// Addresses one part; see the class.
  final NumberedPartsRequest partRequest;

  /// Completes an upload; see the class.
  final NumberedPartsComplete complete;

  @override
  final String id;

  /// The part size of a file up to [bigPartsAbove].
  final int smallPartSize;

  /// The part size of a file over [bigPartsAbove].
  final int bigPartSize;

  /// The largest file sent in [smallPartSize] parts.
  final int bigPartsAbove;

  /// The most parts a file is split into: a file that would need more
  /// goes in larger parts, a multiple of its part size.
  final int maxParts;

  /// The bytes of parts outstanding at once.
  final int bytesInFlight;

  /// How long an interrupted upload of a file up to [windowSplit] reopens.
  final Duration smallFileWindow;

  /// How long an interrupted upload of a file over [windowSplit] reopens.
  final Duration bigFileWindow;

  /// The largest file whose upload reopens within [smallFileWindow]: the
  /// lane split.
  final int windowSplit;

  /// How long a stored reference is good.
  final UploadReuse reuse;

  /// Reads a part's acknowledgement from the answer to its request.
  final NumberedPartReceipt receiptOf;

  /// The part size of a file of [size] bytes.
  int partSizeOf(int size) {
    final base = size > bigPartsAbove ? bigPartSize : smallPartSize;
    if (size <= base * maxParts) return base;
    // The smallest multiple of the base that keeps the count within
    // maxParts: parts stay aligned to the size the remote end expects.
    final needed = (size + maxParts - 1) ~/ maxParts;
    return (needed + base - 1) ~/ base * base;
  }

  /// The resume window of a file of [size] bytes.
  Duration windowOf(int size) =>
      size > windowSplit ? bigFileWindow : smallFileWindow;

  @override
  late final UploadCapabilities capabilities = UploadCapabilities(
    partSize: partSizeOf,
    bytesInFlight: bytesInFlight,
    resume: UploadResume.window(windowOf),
    thumbnail: UploadThumbnail.separate,
    reuse: reuse,
  );

  @override
  Future<UploadSession> open(UploadInfo info, {String? resumeToken}) async {
    if (resumeToken != null) {
      return _NumberedPartsSession(this, resumeToken, resumed: true);
    }
    return _NumberedPartsSession(this, await start(info), resumed: false);
  }

  /// The `ETag` header of [response], the receipt S3, R2 and GCS give a
  /// part; null when the answer has none.
  static String? etagOf(HttpBytesResponse response) {
    for (final MapEntry(:key, :value) in response.headers.entries) {
      if (key.toLowerCase() == 'etag') return value;
    }
    return null;
  }
}

final class _NumberedPartsSession implements UploadSession {
  _NumberedPartsSession(
    this._transport,
    this.resumeToken, {
    required this.resumed,
  });

  final NumberedPartsTransport _transport;

  /// The upload id, which is also what reopens the upload.
  @override
  final String resumeToken;

  @override
  final bool resumed;

  @override
  DateTime? get resumeExpiresAt => null;

  @override
  Future<UploadPartAck> sendPart(
    int index,
    int offset,
    UploadPartBody bytes, {
    required bool last,
  }) async {
    final request = await _transport.partRequest(
      NumberedPart(
        uploadId: resumeToken,
        number: index + 1,
        offset: offset,
        length: bytes.length,
        last: last,
      ),
    );
    final response = await bytes.send(
      request.url,
      method: request.method,
      headers: request.headers,
    );
    return UploadPartAck(receipt: _transport.receiptOf(response));
  }

  @override
  Future<RemoteRef> finish(int finalSize, List<UploadPartAck> parts) =>
      _transport.complete(
        NumberedPartsCompletion(
          uploadId: resumeToken,
          size: finalSize,
          parts: [
            for (var i = 0; i < parts.length; i++)
              NumberedPartAck(number: i + 1, receipt: parts[i].receipt),
          ],
        ),
      );
}

/// One part of a numbered-parts upload, as [NumberedPartsTransport]
/// asks the host to address it.
@immutable
final class NumberedPart {
  /// Part [number] of upload [uploadId]: [length] bytes from [offset].
  const NumberedPart({
    required this.uploadId,
    required this.number,
    required this.offset,
    required this.length,
    required this.last,
  });

  /// What the host's start answered for the upload.
  final String uploadId;

  /// The part's number, from 1, as multipart stores count them.
  final int number;

  /// Where the part starts in the file.
  final int offset;

  /// The part's size in bytes: its request's `Content-Length`.
  final int length;

  /// Whether this is the file's final part.
  final bool last;

  @override
  bool operator ==(Object other) =>
      other is NumberedPart &&
      other.uploadId == uploadId &&
      other.number == number &&
      other.offset == offset &&
      other.length == length &&
      other.last == last;

  @override
  int get hashCode => Object.hash(uploadId, number, offset, length, last);

  @override
  String toString() => 'NumberedPart($number, $length bytes at $offset)';
}

/// Where one part goes: a [method] request (`PUT` by default) to [url]
/// with [headers], carrying the part's bytes as its body.
@immutable
final class NumberedPartRequest {
  /// A request for one part.
  const NumberedPartRequest(this.url, {this.method = 'PUT', this.headers});

  /// Where the part goes; for presigned multipart, the signed URL.
  final Uri url;

  /// `PUT`, `POST` or `PATCH`.
  final String method;

  /// Headers the part's request carries.
  final Map<String, String>? headers;

  // The URL may carry a signature: it stays out of logs.
  @override
  String toString() => 'NumberedPartRequest($method)';
}

/// One acknowledged part, as [NumberedPartsCompletion.parts] lists it.
@immutable
final class NumberedPartAck {
  /// Part [number]'s acknowledgement, [receipt].
  const NumberedPartAck({required this.number, this.receipt});

  /// The part's number, from 1.
  final int number;

  /// What the remote end acknowledged the part with (an `ETag`, a part
  /// id); null when it gave nothing.
  final String? receipt;

  @override
  bool operator ==(Object other) =>
      other is NumberedPartAck &&
      other.number == number &&
      other.receipt == receipt;

  @override
  int get hashCode => Object.hash(number, receipt);

  @override
  String toString() => 'NumberedPartAck($number)';
}

/// What [NumberedPartsTransport.complete] is given: the upload, its size
/// and every part's acknowledgement.
@immutable
final class NumberedPartsCompletion {
  /// The completion of upload [uploadId].
  NumberedPartsCompletion({
    required this.uploadId,
    required this.size,
    required List<NumberedPartAck> parts,
  }) : parts = List.unmodifiable(parts);

  /// What the host's start answered for the upload.
  final String uploadId;

  /// The file's size in bytes.
  final int size;

  /// Every part's acknowledgement in number order, from 1, those of an
  /// earlier session of the upload included.
  final List<NumberedPartAck> parts;

  @override
  String toString() => 'NumberedPartsCompletion(${parts.length} parts)';
}
