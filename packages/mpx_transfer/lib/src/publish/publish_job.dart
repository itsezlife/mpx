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

  /// Retries the job after a failure, repeating only what failed: each
  /// failed item goes back to where it failed, keeping a finished
  /// preparation and every journaled upload (a failed upload goes on from
  /// the parts it sent), and a job failed at the publish stage publishes
  /// again with the same idempotency key and uploads nothing.
  ///
  /// Also takes every failed item of a running job (per-item policy) back
  /// to work. Answers false when there is nothing to retry: an unknown or
  /// completed job, or one with no failure.
  bool retry() => _jobs.retry(id);

  /// Retries item [itemId] alone, as [retry] does for each failed item. A
  /// job failed by the item (whole-job policy) runs again; one with another
  /// failed item fails again at once.
  ///
  /// Answers false for an item that has not failed or a completed job.
  bool retryItem(String itemId) => _jobs.retryItem(id, itemId);

  /// Removes item [itemId] from the job before it publishes: its uploads
  /// and its preparation stop, and the job goes on with the other items,
  /// publishing once each of them is uploaded. With the per-item policy,
  /// that is how a host gives up on a failed item.
  ///
  /// Answers false for an unknown item, a job that ended, or the job's
  /// last item.
  bool removeItem(String itemId) => _jobs.removeItem(id, itemId);

  @override
  bool operator ==(Object other) => other is PublishJob && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PublishJob($id)';
}
