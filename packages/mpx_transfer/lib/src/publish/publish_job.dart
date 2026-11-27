import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/publish/publish_jobs.dart';
import 'package:mpx_transfer/src/publish/publish_request.dart';
import 'package:mpx_transfer/src/publish/publish_state.dart';

/// A host's handle on one publish job, from `Transfers.publish`,
/// `Transfers.upload` or, after a restart, `Transfers.publishJob`.
///
/// The job runs in the engine, not in this object: dropping the handle
/// changes nothing, and any number of handles watch the same job.
@immutable
final class PublishJob {
  /// A handle on job [id] of [_jobs].
  @internal
  const PublishJob(this._jobs, this.id);

  final PublishJobs _jobs;

  /// The job's identity: what an owner keeps to find it again.
  final PublishJobId id;

  /// The job now. Throws a [StateError] once the engine no longer has it.
  PublishJobSnapshot get snapshot =>
      _jobs.snapshotOf(id) ??
      (throw StateError('The publish job is no longer known.'));

  /// Snapshots of the job: the current one on listen, then the job again
  /// whenever it changes. Ends when the engine shuts down.
  Stream<PublishJobSnapshot> watch() => _jobs.watch(id);

  /// Snapshots of item [itemId], as [watch] gives the job's. Throws an
  /// [ArgumentError] on listen for an id the job does not have.
  Stream<PublishItemSnapshot> watchItem(String itemId) =>
      _jobs.watchItem(id, itemId);

  @override
  bool operator ==(Object other) => other is PublishJob && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PublishJob($id)';
}
