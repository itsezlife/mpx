import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';

/// Which way a transfer job moves bytes.
enum TransferDirection {
  /// From the device to a remote end, through an upload transport.
  upload,

  /// From a remote end into the bytes cache.
  download,
}

/// How hard the platform is asked to keep a transfer job going.
///
/// Neither level survives a force quit, a Task Manager stop or a force stop;
/// a job interrupted that way resumes when the engine starts again.
enum TransferDurability {
  /// Runs while the process lives.
  inProcess,

  /// The same in-process transfer run inside an OS envelope, so it keeps
  /// going in the background where the platform allows. Where the platform
  /// has no envelope, the job runs [inProcess].
  system,
}

/// One transfer job as a query sees it: a snapshot, never updated in place.
///
/// Equal by value, so a watcher can tell whether anything it shows changed.
@immutable
final class TransferJob {
  /// A snapshot of a job.
  const TransferJob({
    required this.id,
    required this.direction,
    required this.durability,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    this.tag,
    this.key,
    this.priority = RequestPriority.visible,
    this.resumeOnStart = true,
  });

  /// The job's identity.
  final TransferId id;

  /// Upload or download.
  final TransferDirection direction;

  /// How hard the platform is asked to keep the job going.
  final TransferDurability durability;

  /// Where the job is.
  final TransferState state;

  /// The host's value for the job, carried as given and never read by the
  /// engine: an owner finds its jobs by it, after a restart too. Null when
  /// the host gave none.
  final String? tag;

  /// The content a download fetches, or the item an upload of a publish
  /// job sends; null for an upload made on its own.
  final MediaKey? key;

  /// How urgently the job's bytes are needed.
  final RequestPriority priority;

  /// Whether the job resumes by itself when the engine starts again after
  /// the process ended. False for a download nobody asked for explicitly: it
  /// comes back paused until something shows its content.
  final bool resumeOnStart;

  /// When the job was made.
  final DateTime createdAt;

  /// When its state last changed, progress included. A completed job is
  /// kept for the retention period from this time.
  final DateTime updatedAt;

  /// This snapshot with the given parts replaced; the engine's way of
  /// moving a job on.
  @internal
  TransferJob copyWith({
    TransferState? state,
    RequestPriority? priority,
    DateTime? updatedAt,
    bool? resumeOnStart,
  }) => TransferJob(
    id: id,
    direction: direction,
    durability: durability,
    state: state ?? this.state,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    tag: tag,
    key: key,
    priority: priority ?? this.priority,
    resumeOnStart: resumeOnStart ?? this.resumeOnStart,
  );

  @override
  bool operator ==(Object other) =>
      other is TransferJob &&
      other.id == id &&
      other.direction == direction &&
      other.durability == durability &&
      other.state == state &&
      other.tag == tag &&
      other.key == key &&
      other.priority == priority &&
      other.resumeOnStart == resumeOnStart &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    direction,
    durability,
    state,
    tag,
    key,
    priority,
    resumeOnStart,
    createdAt,
    updatedAt,
  );

  @override
  String toString() =>
      'TransferJob($id, ${direction.name}, ${durability.name}, $state'
      '${tag == null ? '' : ', tag: $tag'})';
}

/// Which transfer jobs a `Transfers.watch` query sees. Every part left out
/// matches every job; the parts given must all match.
@immutable
final class TransferFilter {
  /// A filter; with nothing given, every job.
  const TransferFilter({this.direction, this.state, this.tag, this.durability});

  /// Only jobs moving bytes this way.
  final TransferDirection? direction;

  /// Only jobs whose state passes this test, such as
  /// `(state) => state is TransferState$Paused`.
  final bool Function(TransferState state)? state;

  /// Only jobs carrying exactly this tag.
  final String? tag;

  /// Only jobs of this durability.
  final TransferDurability? durability;

  /// Whether [job] passes every part given.
  bool matches(TransferJob job) =>
      (direction == null || job.direction == direction) &&
      (tag == null || job.tag == tag) &&
      (durability == null || job.durability == durability) &&
      (state?.call(job.state) ?? true);
}
