import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_transfer/src/engine/transfer_runner.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';

/// A runner that moves no bytes: a test says what each running job reports,
/// and reads what the engine asked of the runner.
final class ScriptedTransferRunner implements TransferRunner {
  final Map<TransferId, TransferRunSink> _running = {};
  final List<TransferJob> _starts = [];
  final List<TransferId> _stops = [];
  final List<(TransferId, RequestPriority)> _priorities = [];

  /// The job of every start, as the engine handed it, oldest first.
  List<TransferJob> get starts => List.unmodifiable(_starts);

  /// Every stop, oldest first.
  List<TransferId> get stops => List.unmodifiable(_stops);

  /// Every priority change, oldest first.
  List<(TransferId, RequestPriority)> get priorities =>
      List.unmodifiable(_priorities);

  /// Whether job [id] was started and has not stopped, completed or failed.
  bool isRunning(TransferId id) => _running.containsKey(id);

  @override
  void start(TransferJob job, TransferRunSink sink) {
    _starts.add(job);
    _running[job.id] = sink;
  }

  @override
  void stop(TransferId id) {
    _stops.add(id);
    _running.remove(id);
  }

  @override
  void reprioritize(TransferId id, RequestPriority priority) =>
      _priorities.add((id, priority));

  /// Job [id] moved [done] bytes of [total].
  void progress(
    TransferId id,
    int done, {
    int? total,
    bool estimated = false,
  }) => _sink(id).progress(done, total: total, estimated: estimated);

  /// Job [id] completed with [result].
  void complete(TransferId id, TransferResult result) {
    final sink = _sink(id);
    _running.remove(id);
    sink.complete(result);
  }

  /// Job [id]'s attempt failed.
  void fail(TransferId id, TransferFailureKind kind, {bool retryable = true}) {
    final sink = _sink(id);
    _running.remove(id);
    sink.fail(kind, retryable: retryable);
  }

  TransferRunSink _sink(TransferId id) =>
      _running[id] ?? (throw StateError('Job $id is not running.'));
}
