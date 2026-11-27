import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/upload/upload_lane.dart';

/// The transfer engine's state at one moment, for a debug panel: read on
/// demand through `Transfers.debugSnapshot`, never streamed.
///
/// Sections arrive with the parts of the engine they describe; this one
/// holds the jobs, connectivity, the journal, and, where the engine runs
/// them, the uploads and the shared connections.
@immutable
final class TransfersDebugSnapshot {
  /// A snapshot of [jobs], [online] and [journal].
  TransfersDebugSnapshot({
    required List<TransferJob> jobs,
    required this.online,
    required this.journal,
    this.uploads,
    this.connections,
    this.reuse,
  }) : jobs = List.unmodifiable(jobs);

  /// Every job not yet completed, oldest first, with its id, tag,
  /// direction, state (and pause reason), durability, bytes and times.
  final List<TransferJob> jobs;

  /// Connectivity as the composition root last reported it.
  final bool online;

  /// Where the jobs are kept, and how far behind memory it is.
  final JournalDebugSnapshot journal;

  /// The upload lanes and counters; null for an engine that runs no
  /// uploads.
  final UploadsDebugSnapshot? uploads;

  /// The shared connections in use against their caps; null for an engine
  /// that runs no requests of its own.
  final ConnectionsDebugSnapshot? connections;

  /// The reuse table: entries, hits and misses; null for an engine opened
  /// without one.
  final ReuseDebugSnapshot? reuse;

  @override
  String toString() =>
      'TransfersDebugSnapshot(${jobs.length} jobs, online: $online, '
      '$journal${uploads == null ? '' : ', $uploads'}'
      '${connections == null ? '' : ', $connections'}'
      '${reuse == null ? '' : ', $reuse'})';
}

/// The reuse table's section of a [TransfersDebugSnapshot].
@immutable
final class ReuseDebugSnapshot {
  /// A snapshot of the table.
  const ReuseDebugSnapshot({
    required this.enabled,
    required this.entries,
    required this.hits,
    required this.misses,
  });

  /// Whether the host has the table on.
  final bool enabled;

  /// How many sources the table holds references for.
  final int entries;

  /// Lookups since start that skipped preparation and upload.
  final int hits;

  /// Lookups since start that found nothing good (the table on).
  final int misses;

  @override
  String toString() =>
      'ReuseDebugSnapshot(enabled: $enabled, $entries entries, '
      '$hits hits, $misses misses)';
}

/// The uploads section of a [TransfersDebugSnapshot]: the lanes, and
/// counters since the engine started.
@immutable
final class UploadsDebugSnapshot {
  /// A snapshot of the uploads.
  UploadsDebugSnapshot({
    required Map<UploadLane, UploadLaneDebugSnapshot> lanes,
    required this.partsInFlight,
    required this.partRetries,
    required this.restartsFromZero,
  }) : lanes = Map.unmodifiable(lanes);

  /// Each lane: the job it runs and how many wait.
  final Map<UploadLane, UploadLaneDebugSnapshot> lanes;

  /// Parts sent and not yet acknowledged, now.
  final int partsInFlight;

  /// Tries of a part (or of opening or finishing) that failed and were
  /// tried again, since the engine started.
  final int partRetries;

  /// Uploads that had acknowledged parts but started again from zero,
  /// since the engine started.
  final int restartsFromZero;

  @override
  String toString() =>
      'UploadsDebugSnapshot(${[for (final MapEntry(:key, :value) in lanes.entries) '${key.name}: $value'].join(', ')}, '
      '$partsInFlight in flight, $partRetries retries, '
      '$restartsFromZero restarts)';
}

/// One lane of an [UploadsDebugSnapshot].
@immutable
final class UploadLaneDebugSnapshot {
  /// A lane running [running], with [queued] jobs waiting.
  const UploadLaneDebugSnapshot({required this.queued, this.running});

  /// The job the lane runs; null when it is free.
  final TransferId? running;

  /// Jobs waiting for the lane.
  final int queued;

  @override
  String toString() => '${running ?? 'free'} + $queued queued';
}

/// The connections section of a [TransfersDebugSnapshot]: the requests on
/// the wire per direction against the caps.
@immutable
final class ConnectionsDebugSnapshot {
  /// A snapshot of the connections.
  const ConnectionsDebugSnapshot({
    required this.cap,
    required this.downloadCap,
    required this.uploadCap,
    required this.downloads,
    required this.uploads,
    required this.waiting,
  });

  /// Connections over both directions.
  final int cap;

  /// Connections downloads may hold.
  final int downloadCap;

  /// Connections uploads may hold.
  final int uploadCap;

  /// Connections downloads hold now.
  final int downloads;

  /// Connections uploads hold now.
  final int uploads;

  /// Requests waiting for a connection.
  final int waiting;

  @override
  String toString() =>
      'ConnectionsDebugSnapshot(downloads $downloads/$downloadCap, '
      'uploads $uploads/$uploadCap, cap $cap, $waiting waiting)';
}

/// The journal section of a [TransfersDebugSnapshot].
@immutable
final class JournalDebugSnapshot {
  /// A snapshot of the journal.
  const JournalDebugSnapshot({
    required this.store,
    required this.bytes,
    required this.recordsSinceCompaction,
    this.lastStateWriteAt,
    this.lastProgressFlushAt,
  });

  /// The storage's kind: `file`, `opfs` or `memory`.
  final String store;

  /// The journal's size in storage: the snapshot and the log.
  final int bytes;

  /// Records appended to the log since it was last folded into the
  /// snapshot.
  final int recordsSinceCompaction;

  /// When a state change was last written and flushed; null before any in
  /// this run.
  final DateTime? lastStateWriteAt;

  /// When a progress batch was last written and flushed; null before any in
  /// this run.
  final DateTime? lastProgressFlushAt;

  @override
  String toString() =>
      'JournalDebugSnapshot($store, $bytes bytes, '
      '$recordsSinceCompaction since compaction)';
}
