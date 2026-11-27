import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';

/// What moves a transfer job's bytes, for the engine that owns its state.
///
/// The engine decides when a job runs and what state it is in; a runner
/// only moves bytes and reports through the [TransferRunSink] of each run.
/// Uploads through a transport and downloads through the bytes cache are
/// the runners to come; engine tests drive `ScriptedTransferRunner`.
///
/// Internal to the package: hosts never see a runner.
abstract interface class TransferRunner {
  /// Starts moving [job]'s bytes, continuing from what earlier attempts kept;
  /// reports through [sink] until it completes, fails, or is stopped.
  void start(TransferJob job, TransferRunSink sink);

  /// Stops moving job [id]'s bytes, keeping what moved: the job paused, was
  /// cancelled, or its envelope ended. Reports after this are ignored.
  void stop(TransferId id);

  /// Job [id] is now needed at [priority].
  void reprioritize(TransferId id, RequestPriority priority);
}

/// Where one run of a job reports. Calls after the run ended (it completed,
/// failed or was stopped) are ignored.
abstract interface class TransferRunSink {
  /// [done] bytes of [total] (null when unknown) have moved; [estimated]
  /// while [total] is an estimate. The first report of a run starts it.
  void progress(int done, {int? total, bool estimated});

  /// The transfer is done and produced [result].
  void complete(TransferResult result);

  /// The attempt failed. A [TransferFailureKind.network] failure while the
  /// device is offline pauses the job until connectivity comes back instead.
  void fail(TransferFailureKind kind, {required bool retryable});
}
