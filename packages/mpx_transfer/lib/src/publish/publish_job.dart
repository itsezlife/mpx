import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
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

  /// The job's payload now, as `snapshot.payload` gives it: after a
  /// restart too, byte for byte. Throws a [StateError] once the engine no
  /// longer has the job.
  Uint8List get payload => snapshot.payload;

  /// Snapshots of the job: the current one on listen, then the job again
  /// whenever it changes. Ends when the engine shuts down.
  Stream<PublishJobSnapshot> watch() => _jobs.watch(id);

  /// Snapshots of item [itemId], as [watch] gives the job's. Once the item
  /// leaves the job (removed, or one of its uploads cancelled) the last
  /// snapshot is `removed` and the stream ends. Throws an [ArgumentError]
  /// on listen for an id the job does not have.
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
  /// With [source] the item's file uploads from it, from zero: the host's
  /// way back from a source lost (on the web, a reload that kept no copy;
  /// the user picks the file again). It replaces the item's page source
  /// (`PublishItem.pageSource`) too; on the VM it is written to a file
  /// first.
  ///
  /// Answers false for an item that has not failed or a completed job.
  bool retryItem(String itemId, {SourceBytes? source}) =>
      _jobs.retryItem(id, itemId, source: source);

  /// Removes item [itemId] from the job: its uploads and its preparation
  /// stop, and the job goes on with the other items, publishing once each
  /// of them is uploaded. With the per-item policy, that is how a host
  /// gives up on a failed item. Allowed until the job ends, during the
  /// publisher's call too (the remote end then deals with an item it was
  /// sent).
  ///
  /// Removing the last item leaves the job `awaitingOwner`: it publishes
  /// nothing until its owner [commit]s it (the payload alone, or, for a
  /// held job, the items it adds) or [cancel]s it; the engine never
  /// decides that for it. A cancel of one of the item's uploads
  /// (`Transfers.cancel`) removes the item the same way.
  ///
  /// Answers false for an unknown item or a job that ended.
  bool removeItem(String itemId) => _jobs.removeItem(id, itemId);

  /// Adds [item] at the end of a held job not committed yet; it prepares
  /// and uploads at once. A job waiting for its owner goes on.
  ///
  /// Answers false once the job publishes (it was made without `hold`, or
  /// committed) or ended. Throws as `Transfers.publish` does for a bad
  /// item: an id the job has, an item that needs preparation on a facade
  /// without it, or an item to upload when the facade has no transport.
  bool addItem(PublishItem item) => _jobs.addItem(id, item);

  /// Puts the items of a held job not committed yet in the order of
  /// [itemIds], each of the job's item ids once (an [ArgumentError]
  /// otherwise). Answers false once the job publishes or ended.
  bool reorder(List<String> itemIds) => _jobs.reorder(id, itemIds);

  /// Replaces the payload of a held job not committed yet. Answers false
  /// once the job publishes or ended.
  bool setPayload(Uint8List payload) => _jobs.setPayload(id, payload);

  /// Lets the job publish: a held job once its items are uploaded, a job
  /// waiting for its owner with what it has left. With [payload] the job
  /// publishes that instead of the one it has. In an ordering group the job
  /// takes its place at the end of the line now.
  ///
  /// Answers false for any other job: one that already publishes or ended.
  bool commit({Uint8List? payload}) => _jobs.commit(id, payload);

  /// Cancels the job in any state: its preparations stop, its uploads are
  /// cancelled (what a held job uploaded included), and it is removed, so
  /// its watchers end and `Transfers.watchJobs` lists it no more. Jobs
  /// behind it in its ordering group go on.
  ///
  /// Answers false for a job the engine no longer has.
  bool cancel() => _jobs.cancelByOwner(id);

  @override
  bool operator ==(Object other) => other is PublishJob && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PublishJob($id)';
}
