import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/upload/upload_lane.dart';

/// What the journal keeps of one transfer job: the job as queries see it,
/// and what a restart needs to go on with it.
///
/// An upload's facts ([upload]: source, transport, resume token,
/// acknowledged parts) are filled by the upload engine, the envelope handle
/// by the OS envelope; a download leaves them empty.
@immutable
final class JournalRecord {
  /// A record of [job].
  const JournalRecord({
    required this.job,
    this.upload,
    this.envelopeHandle,
    this.lastProgressAt,
  });

  /// The job: id, direction, tag, durability, priority, created time,
  /// state and result.
  final TransferJob job;

  /// What an upload reads, through which transport, and how far it got;
  /// null for a download.
  final JournalUpload? upload;

  /// The OS envelope's handle for the job, matched against what the native
  /// part left at a restart.
  final String? envelopeHandle;

  /// When progress was last written for the job; null before any.
  final DateTime? lastProgressAt;

  /// This record with the given parts replaced.
  JournalRecord copyWith({
    TransferJob? job,
    JournalUpload? upload,
    String? envelopeHandle,
    DateTime? lastProgressAt,
  }) => JournalRecord(
    job: job ?? this.job,
    upload: upload ?? this.upload,
    envelopeHandle: envelopeHandle ?? this.envelopeHandle,
    lastProgressAt: lastProgressAt ?? this.lastProgressAt,
  );

  @override
  bool operator ==(Object other) =>
      other is JournalRecord &&
      other.job == job &&
      other.upload == upload &&
      other.envelopeHandle == envelopeHandle &&
      other.lastProgressAt == lastProgressAt;

  @override
  int get hashCode => Object.hash(job, upload, envelopeHandle, lastProgressAt);

  @override
  String toString() => 'JournalRecord($job)';
}

/// An upload's facts in the journal: the file, the transport that carries
/// it and the parts the remote end acknowledged, so a restart sends only
/// what is missing.
@immutable
final class JournalUpload {
  /// An upload of [source] through transport [transportId], split into
  /// parts of [partSize] bytes.
  JournalUpload({
    required this.source,
    required this.transportId,
    required this.lane,
    required this.partSize,
    this.fileName,
    this.contentType,
    this.resumeToken,
    this.resumeExpiresAt,
    Map<int, String?> parts = const {},
    this.highWaterMark = 0,
    this.owner,
  }) : parts = Map.unmodifiable(parts);

  /// The file the upload reads.
  final JournalSource source;

  /// The id of the upload transport that carries the job.
  final String transportId;

  /// The lane the job waits in.
  final UploadLane lane;

  /// The size of every part but the last, as the transport declared it
  /// when the job was made. Parts acknowledged under one size say nothing
  /// about a split by another.
  final int partSize;

  /// The file's name for the remote end, when the host gave one.
  final String? fileName;

  /// The file's media type for the remote end, when the host gave one.
  final String? contentType;

  /// The transport's token for reopening an interrupted upload.
  final String? resumeToken;

  /// When the remote end forgets the upload [resumeToken] reopens, as its
  /// session said; null when it did not say.
  final DateTime? resumeExpiresAt;

  /// The parts the remote end acknowledged, by index, each with the
  /// receipt it answered (an ETag, a part id), or null when it gave none.
  final Map<int, String?> parts;

  /// The bytes from the start of the source that are known sent: every
  /// part that ends at or before it is acknowledged.
  final int highWaterMark;

  /// The publish job item this upload sends, when a publish job made it;
  /// null for an upload made on its own.
  final JournalUploadOwner? owner;

  /// This upload with the given parts replaced; [clearResumeToken] drops
  /// the token and its expiry.
  JournalUpload copyWith({
    JournalSource? source,
    String? resumeToken,
    bool clearResumeToken = false,
    Map<int, String?>? parts,
    int? highWaterMark,
  }) => JournalUpload(
    source: source ?? this.source,
    transportId: transportId,
    lane: lane,
    partSize: partSize,
    fileName: fileName,
    contentType: contentType,
    resumeToken: clearResumeToken ? null : resumeToken ?? this.resumeToken,
    resumeExpiresAt: clearResumeToken ? null : resumeExpiresAt,
    parts: parts ?? this.parts,
    highWaterMark: highWaterMark ?? this.highWaterMark,
    owner: owner,
  );

  @override
  bool operator ==(Object other) =>
      other is JournalUpload &&
      other.source == source &&
      other.transportId == transportId &&
      other.lane == lane &&
      other.partSize == partSize &&
      other.fileName == fileName &&
      other.contentType == contentType &&
      other.resumeToken == resumeToken &&
      other.resumeExpiresAt == resumeExpiresAt &&
      _sameParts(other.parts, parts) &&
      other.highWaterMark == highWaterMark &&
      other.owner == owner;

  @override
  int get hashCode => Object.hash(
    source,
    transportId,
    lane,
    partSize,
    fileName,
    contentType,
    resumeToken,
    resumeExpiresAt,
    Object.hashAllUnordered(
      parts.entries.map((part) => Object.hash(part.key, part.value)),
    ),
    highWaterMark,
    owner,
  );

  @override
  String toString() =>
      'JournalUpload($transportId, ${lane.name}, ${parts.length} parts, '
      '$highWaterMark)';
}

/// Which part of which publish job item an upload sends: what lets a
/// restart match an upload to its item when the two were written to their
/// stores in another order than they were made.
@immutable
final class JournalUploadOwner {
  /// The upload of [role] for item [itemId] of publish job [job].
  const JournalUploadOwner({
    required this.job,
    required this.itemId,
    required this.role,
  });

  /// The publish job's id.
  final String job;

  /// The item's id, as the host gave it.
  final String itemId;

  /// What of the item the upload sends.
  final UploadRole role;

  @override
  bool operator ==(Object other) =>
      other is JournalUploadOwner &&
      other.job == job &&
      other.itemId == itemId &&
      other.role == role;

  @override
  int get hashCode => Object.hash(job, itemId, role);
}

/// What of a publish job item an upload sends.
enum UploadRole {
  /// The item's file.
  file,

  /// The item's thumbnail, for a transport that takes it separately.
  thumbnail,
}

bool _sameParts(Map<int, String?> a, Map<int, String?> b) {
  if (a.length != b.length) return false;
  for (final MapEntry(:key, :value) in a.entries) {
    if (!b.containsKey(key) || b[key] != value) return false;
  }
  return true;
}

/// The file an upload reads, as the journal keeps it to tell at a restart
/// whether it is still the same file.
@immutable
final class JournalSource {
  /// A source at [path].
  const JournalSource({
    required this.path,
    required this.size,
    required this.fingerprint,
    this.growing = false,
    this.modified,
  });

  /// Where the file is.
  final String path;

  /// Its size in bytes when last read; for a [growing] file, what was
  /// there then.
  final int size;

  /// Whether the file was still being written.
  final bool growing;

  /// What identifies the file's content: the host's value, else its size.
  /// Whether the file at [path] changed under a running upload is told by
  /// [size] and [modified].
  final String fingerprint;

  /// When the file was last written, as the engine read it when the upload
  /// last began; null before the first run, or where the engine reads no
  /// file system (the web). With [size] it tells at a restart whether the
  /// file is still the one the acknowledged parts came from.
  final DateTime? modified;

  @override
  bool operator ==(Object other) =>
      other is JournalSource &&
      other.path == path &&
      other.size == size &&
      other.growing == growing &&
      other.fingerprint == fingerprint &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(path, size, growing, fingerprint, modified);
}
