import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of publish jobs, category `publish`: a job
/// made, its items moving through their stages, waiting for and finding
/// its publisher, and each publish attempt with its outcome.
///
/// No field carries user content: never the payload, a path, a remote
/// reference or the idempotency key, only counts, stage names, ids and
/// whether the key was the request's. The job, item, media key and tag are
/// the event's correlation ids.
enum PublishOp implements DiagnosticOp {
  /// A job was made (info; `items`, `publisher`, `durability`,
  /// `failurePolicy`, `hold`, `group` (bool), `idempotency`: `request` or
  /// `engine`; job, tag).
  jobCreated,

  /// An item moved from one stage to another (debug; `from`, `to`; job,
  /// item, key). A move to `failed` is an error and adds `stage` and
  /// `reason`.
  itemStage,

  /// An item goes as remote, with nothing to upload (debug; job, item,
  /// key).
  remoteItem,

  /// Everything is uploaded and no publisher is registered under the job's
  /// id, so the job waits (warning; `publisher`; job, tag).
  awaitingPublisher,

  /// A publisher was registered (info; `publisher`, `jobsWaiting`, the
  /// jobs it lets go on).
  publisherRegistered,

  /// A publish attempt began (info; `attempt`, from 1; `stage`; job, tag).
  attempt,

  /// The publisher answered (info; `outcome`, `retryable`, `serverKeys`,
  /// the number of keys; job, tag). A `rejected` answer is a warning, a
  /// `reuploadItems` one adds `items`, the number of items sent again, and
  /// a publisher that threw is an error with `outcome: error`.
  outcome,

  /// After a `published` answer, one item's server key was aliased to its
  /// local key in the bytes cache (debug; `result`: `aliased`,
  /// `nothingHeld` when the local key held no bytes, `noCache` when the
  /// facade has no bytes cache, `unknownItem` for a key of an item the job
  /// does not have; job, item, key). An alias that threw is a warning with
  /// `result: failed`.
  aliasApplied,

  /// A second `reuploadItems` answer, which fails the job at the publish
  /// stage (error; job, tag).
  reuploadRefused,

  /// The host retried a failed job or item (info; `stage`, the failed
  /// step; `items`, the items sent back to work; job, tag, and the item
  /// for an item's retry).
  retry,

  /// The host removed an item from a job (info; `by`: `host`; job, item,
  /// key, tag).
  itemRemoved;

  @override
  String get category => 'publish';
}

/// The diagnostics operations a publish job reports about preparation,
/// category `preparation`. The preparation itself reports its own through
/// the seam's implementation.
enum PublishPreparationOp implements DiagnosticOp {
  /// An item needs preparation and the facade has no `MediaPreparation`,
  /// so the job is refused, or after a restart the item fails (error;
  /// job, item).
  refusedNoSeam;

  @override
  String get category => 'preparation';
}
