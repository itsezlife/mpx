import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';

/// What the journal keeps of one transfer job: the job as queries see it,
/// and what a restart needs to go on with it.
///
/// The upload parts (source, transport, acknowledged parts, envelope
/// handle) are filled by the upload engine and the OS envelope; a download
/// leaves them empty.
@immutable
final class JournalRecord {
  /// A record of [job].
  JournalRecord({
    required this.job,
    this.source,
    this.transportId,
    this.resumeToken,
    List<int> acknowledgedParts = const [],
    this.highWaterMark = 0,
    this.envelopeHandle,
    this.lastProgressAt,
  }) : acknowledgedParts = List.unmodifiable(acknowledgedParts);

  /// The job: id, direction, tag, durability, priority, created time,
  /// state and result.
  final TransferJob job;

  /// The file an upload reads; null for a download.
  final JournalSource? source;

  /// The upload transport that carries the job.
  final String? transportId;

  /// The transport's token for reopening an interrupted upload.
  final String? resumeToken;

  /// The indexes of the parts the remote end acknowledged.
  final List<int> acknowledgedParts;

  /// The bytes from the start of the source that are known sent.
  final int highWaterMark;

  /// The OS envelope's handle for the job, matched against what the native
  /// part left at a restart.
  final String? envelopeHandle;

  /// When progress was last written for the job; null before any.
  final DateTime? lastProgressAt;

  /// This record with the given parts replaced.
  JournalRecord copyWith({TransferJob? job, DateTime? lastProgressAt}) =>
      JournalRecord(
        job: job ?? this.job,
        source: source,
        transportId: transportId,
        resumeToken: resumeToken,
        acknowledgedParts: acknowledgedParts,
        highWaterMark: highWaterMark,
        envelopeHandle: envelopeHandle,
        lastProgressAt: lastProgressAt ?? this.lastProgressAt,
      );

  @override
  bool operator ==(Object other) =>
      other is JournalRecord &&
      other.job == job &&
      other.source == source &&
      other.transportId == transportId &&
      other.resumeToken == resumeToken &&
      _sameParts(other.acknowledgedParts, acknowledgedParts) &&
      other.highWaterMark == highWaterMark &&
      other.envelopeHandle == envelopeHandle &&
      other.lastProgressAt == lastProgressAt;

  @override
  int get hashCode => Object.hash(
    job,
    source,
    transportId,
    resumeToken,
    Object.hashAll(acknowledgedParts),
    highWaterMark,
    envelopeHandle,
    lastProgressAt,
  );

  @override
  String toString() => 'JournalRecord($job)';
}

bool _sameParts(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
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
  });

  /// Where the file is.
  final String path;

  /// Its size in bytes when last read; for a [growing] file, what was
  /// there then.
  final int size;

  /// Whether the file was still being written.
  final bool growing;

  /// What identifies the file's content: the host's value, or its size and
  /// modification time.
  final String fingerprint;

  @override
  bool operator ==(Object other) =>
      other is JournalSource &&
      other.path == path &&
      other.size == size &&
      other.growing == growing &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(path, size, growing, fingerprint);
}
