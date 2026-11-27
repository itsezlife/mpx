import 'package:http_bytes_cache/http_bytes_cache.dart' show HttpBytesResponse;
import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';

/// How an upload reaches one kind of remote end: the protocol only.
///
/// The engine, not the transport, splits the file into parts by
/// [UploadCapabilities.partSize], keeps the bytes in flight within
/// [UploadCapabilities.bytesInFlight], retries a failed part, journals each
/// acknowledged part and resumes after a restart. A transport opens a
/// session ([open]), sends the parts the engine hands it
/// ([UploadSession.sendPart]) and finishes ([UploadSession.finish]). It
/// never reads the file: each part's bytes come as an [UploadPartBody] the
/// engine streams from the file.
///
/// Every call may throw; an [UploadTransportException] says whether a try
/// again may succeed, and the bytes cache's `HttpBytesException` is read
/// the same way as for any request.
abstract interface class UploadTransport {
  /// The transport's name in the journal: stable across runs, unique among
  /// the transports given to one engine. Carried in diagnostics, so it
  /// names the protocol, never a URL.
  String get id;

  /// What the transport supports, which the engine plans by.
  UploadCapabilities get capabilities;

  /// Starts the upload described by [info], or with [resumeToken] (from an
  /// earlier session of the same upload) reopens it where the remote end
  /// has it. A transport that cannot reopen answers a new session, with
  /// [UploadSession.resumed] false.
  Future<UploadSession> open(UploadInfo info, {String? resumeToken});
}

/// One upload in progress on the remote end, as an [UploadTransport]
/// opened it.
abstract interface class UploadSession {
  /// What reopens this upload after a restart; null when it cannot be
  /// reopened. The engine journals it as soon as the session is open.
  String? get resumeToken;

  /// Whether the session continues an earlier one (opened with its
  /// resume token), so the parts acknowledged then are still there.
  bool get resumed;

  /// When the remote end forgets the upload, for a transport whose
  /// freshness is the server's ([UploadResume.serverExpiry]); null when it
  /// did not say.
  DateTime? get resumeExpiresAt;

  /// Sends part [index]: [bytes] of the file from [offset]; [last] for the
  /// final part. Answers once the remote end acknowledged it.
  ///
  /// The engine may send a part again (after a failed try, or after a
  /// restart lost its acknowledgement): the same index and offset carry the
  /// same bytes, so a remote end that has it already acknowledges it again.
  Future<UploadPartAck> sendPart(
    int index,
    int offset,
    UploadPartBody bytes, {
    required bool last,
  });

  /// Completes the upload of [finalSize] bytes once every part is
  /// acknowledged; [parts] holds each part's acknowledgement in index
  /// order, from this session or an earlier one. Answers where the file now
  /// lives.
  Future<RemoteRef> finish(int finalSize, List<UploadPartAck> parts);
}

/// What an upload is, as [UploadTransport.open] is told.
@immutable
final class UploadInfo {
  /// An upload of [size] bytes in [partCount] parts of [partSize].
  const UploadInfo({
    required this.size,
    required this.partSize,
    required this.partCount,
    this.fileName,
    this.contentType,
  });

  /// The file's size in bytes.
  final int size;

  /// The size of every part but the last.
  final int partSize;

  /// How many parts the file is sent in; at least one, so an empty file
  /// is one empty part.
  final int partCount;

  /// The file's name for the remote end, when the host gave one.
  final String? fileName;

  /// The file's media type, when the host gave one.
  final String? contentType;

  @override
  bool operator ==(Object other) =>
      other is UploadInfo &&
      other.size == size &&
      other.partSize == partSize &&
      other.partCount == partCount &&
      other.fileName == fileName &&
      other.contentType == contentType;

  @override
  int get hashCode =>
      Object.hash(size, partSize, partCount, fileName, contentType);

  @override
  String toString() => 'UploadInfo($size bytes, $partCount x $partSize)';
}

/// The bytes of one part, as the engine hands them to
/// [UploadSession.sendPart]: [length] bytes of the file, sent as the body
/// of a request by [send]. The transport never reads them.
///
/// The request runs where the engine runs uploads: on the VM on the bytes
/// cache's transfer worker, which streams the range from the file; on the
/// web through `fetch` with a slice of the file. It is sent once: a failed
/// try fails [send], and the engine decides whether to try the part again.
final class UploadPartBody {
  /// A body of [length] bytes that [send] sends.
  @internal
  const UploadPartBody(this.length, this._send);

  /// The part's size: the request's `Content-Length`.
  final int length;

  final UploadPartSend _send;

  /// Sends the part's bytes to [url] as the body of a [method] request
  /// (`POST`, `PUT` or `PATCH`) with [headers], and answers the response;
  /// a status that is not a success throws the bytes cache's exception,
  /// with the answer's body in its data. [context] reaches the request's
  /// middlewares, as for any request of the bytes cache.
  ///
  /// [prefix] and [suffix] are the transport's own framing, sent before and
  /// after the part's bytes (a multipart form's boundary and headers): small
  /// and held in memory. The request's `Content-Length` counts them; the
  /// part's progress counts only its [length].
  Future<HttpBytesResponse> send(
    Uri url, {
    String method = 'PUT',
    Map<String, String>? headers,
    Map<String, Object?>? context,
    List<int> prefix = const [],
    List<int> suffix = const [],
  }) => _send(
    url,
    method: method,
    headers: headers,
    context: context,
    prefix: prefix,
    suffix: suffix,
  );
}

/// How an [UploadPartBody] sends: the engine's request, which the
/// transport only addresses.
@internal
typedef UploadPartSend =
    Future<HttpBytesResponse> Function(
      Uri url, {
      required String method,
      required List<int> prefix,
      required List<int> suffix,
      Map<String, String>? headers,
      Map<String, Object?>? context,
    });

/// The remote end's acknowledgement of one part.
@immutable
final class UploadPartAck {
  /// An acknowledgement, with the [receipt] the remote end gave.
  const UploadPartAck({this.receipt});

  /// What the remote end answered for the part (an ETag, a part id) when a
  /// later call needs it, as [UploadSession.finish] does for some
  /// protocols; null when it gave nothing. Journaled with the part.
  final String? receipt;

  @override
  bool operator ==(Object other) =>
      other is UploadPartAck && other.receipt == receipt;

  @override
  int get hashCode => receipt.hashCode;

  @override
  String toString() => 'UploadPartAck(${receipt == null ? '' : 'receipt'})';
}

/// The size of the parts a file of [size] bytes is split into.
typedef UploadPartSize = int Function(int size);

/// What an [UploadTransport] supports, which the engine plans by.
@immutable
final class UploadCapabilities {
  /// A transport's capabilities.
  const UploadCapabilities({
    required this.partSize,
    required this.reuse,
    this.bytesInFlight = 0,
    this.resume = const UploadResume.none(),
    this.knownSizeRequired = true,
    this.headLastAllowed = false,
    this.thumbnail = UploadThumbnail.none,
  });

  /// The part size for a file of a given size: every part but the last is
  /// this long. Positive.
  final UploadPartSize partSize;

  /// How many bytes of parts may be outstanding at once: the engine starts
  /// another part while the bytes sent and not yet acknowledged, with it,
  /// stay within this budget. One part is always allowed, so 0 (the
  /// default) or a budget under the part size sends one part at a time.
  final int bytesInFlight;

  /// Whether and for how long an interrupted upload reopens.
  final UploadResume resume;

  /// Whether a growing source waits for its final size before the
  /// session opens.
  final bool knownSizeRequired;

  /// Whether a growing source's head may be sent last, once its producer
  /// rewrote it.
  final bool headLastAllowed;

  /// Whether an item's thumbnail goes as an upload of its own.
  final UploadThumbnail thumbnail;

  /// How long a stored [RemoteRef] of this transport stays good for
  /// sending the same media again without an upload.
  final UploadReuse reuse;
}

/// Whether and for how long an [UploadTransport] reopens an interrupted
/// upload with its resume token.
@immutable
sealed class UploadResume {
  const UploadResume();

  /// The transport cannot reopen: an interrupted upload starts from zero.
  const factory UploadResume.none() = UploadResume$None;

  /// Reopens for as long as the remote end keeps the upload, with no
  /// window of its own.
  const factory UploadResume.unlimited() = UploadResume$Unlimited;

  /// Reopens within [window] of a file's size since the upload last moved;
  /// after it, the upload starts from zero.
  const factory UploadResume.window(Duration Function(int size) window) =
      UploadResume$Window;

  /// Reopens until the remote end's expiry, as the session tells it
  /// ([UploadSession.resumeExpiresAt]).
  const factory UploadResume.serverExpiry() = UploadResume$ServerExpiry;
}

/// [UploadResume.none].
final class UploadResume$None extends UploadResume {
  /// See [UploadResume.none].
  const UploadResume$None();
}

/// [UploadResume.unlimited].
final class UploadResume$Unlimited extends UploadResume {
  /// See [UploadResume.unlimited].
  const UploadResume$Unlimited();
}

/// [UploadResume.window].
final class UploadResume$Window extends UploadResume {
  /// See [UploadResume.window].
  const UploadResume$Window(this.window);

  /// The window for a file of a given size.
  final Duration Function(int size) window;
}

/// [UploadResume.serverExpiry].
final class UploadResume$ServerExpiry extends UploadResume {
  /// See [UploadResume.serverExpiry].
  const UploadResume$ServerExpiry();
}

/// Whether an item's thumbnail is uploaded on its own.
enum UploadThumbnail {
  /// The transport takes no thumbnail; the remote end makes its own.
  none,

  /// The thumbnail goes as an upload of its own, beside the item's.
  separate,
}

/// How an [UploadTransport] judges whether a stored [RemoteRef] still
/// names the file, so the same media is sent again without an upload.
@immutable
sealed class UploadReuse {
  const UploadReuse();

  /// A reference is good for [lifetime] after it was stored.
  const factory UploadReuse.lifetime(Duration lifetime) = UploadReuse$Lifetime;

  /// A reference is good while [isValid] says so, a call to the remote end.
  const factory UploadReuse.validity(
    Future<bool> Function(RemoteRef ref) isValid,
  ) = UploadReuse$Validity;
}

/// [UploadReuse.lifetime].
final class UploadReuse$Lifetime extends UploadReuse {
  /// See [UploadReuse.lifetime].
  const UploadReuse$Lifetime(this.lifetime);

  /// How long a stored reference is good.
  final Duration lifetime;
}

/// [UploadReuse.validity].
final class UploadReuse$Validity extends UploadReuse {
  /// See [UploadReuse.validity].
  const UploadReuse$Validity(this.isValid);

  /// Whether the remote end still has the file a reference names.
  final Future<bool> Function(RemoteRef ref) isValid;
}

/// A transport's call failed in a way the transport can name: what failed
/// ([kind]), whether a try again may succeed ([transient]), and the status
/// or the short [code] for diagnostics.
///
/// The message stays out of diagnostics; [code] and [status] carry no user
/// content.
final class UploadTransportException implements Exception {
  /// A failure of [kind], tried again when [transient].
  const UploadTransportException(
    this.code, {
    this.kind = TransferFailureKind.server,
    this.transient = false,
    this.status,
    this.message,
  });

  /// A short, stable name for what failed, such as `expired_session`.
  final String code;

  /// What failed, as the job reports it if the upload gives up.
  final TransferFailureKind kind;

  /// Whether the same call may succeed if tried again.
  final bool transient;

  /// The HTTP status, when the failure was an answer.
  final int? status;

  /// A description for a developer; never reported.
  final String? message;

  @override
  String toString() =>
      'UploadTransportException($code'
      '${status == null ? '' : ', $status'}'
      '${message == null ? '' : ': $message'})';
}
