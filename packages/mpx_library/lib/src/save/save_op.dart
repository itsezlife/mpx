import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of the media saver, category `save`: a batch
/// started, moving, each item's end, and the batch's end.
///
/// Every event carries the `SaveJob`'s id as its `jobId`; an item's events
/// carry `index`, its place in the batch, and, in a `saveContent` batch,
/// the item's `mediaKey`. No field carries user content: no
/// file name, path, album or sub-folder name, and no platform ref; a MIME
/// type goes by its top-level type only (`image`, `video` or `other`).
enum SaveOp implements DiagnosticOp {
  /// A batch began (info; `items`, `destination`, `named` when the host set
  /// an album or a sub-folder, `platform`, and the item count per kind:
  /// `photos`, `videos`, `animations`, `files`).
  jobStarted,

  /// The batch moved (trace; `fraction`, `stage`: `download` while a
  /// `saveContent` item is still arriving, `copy` otherwise).
  progress,

  /// An item was saved (debug; `index`, `kind`, `mime`, `bytes` when
  /// known, `ms` since the batch began, `renamed`).
  itemSaved,

  /// An item failed (warning; `index`, `reason`, `code` when the platform
  /// gave one).
  itemFailed,

  /// An item was cancelled (debug; `index`, `stage`: `download` or
  /// `copy`).
  itemCancelled,

  /// A batch ended (info; `saved`, `cancelled`, `failed`, `ms`).
  jobFinished,

  /// A move asked for a leased (cache) file was refused and the file copied
  /// instead (warning; `index`).
  moveRefused,

  /// A `file` item sent to the gallery was routed by its MIME type (debug;
  /// `index`, `mime`, `outcome`: `gallery` or `unsupportedFormat`).
  routedByMime,

  /// An item's lease was given back (trace; `index`, `after`: `saved`,
  /// `cancelled` or `failed`).
  leaseReleased,

  /// A `saveContent` item not local started its tracked download (debug;
  /// `index`, `origin`: `user`).
  downloadStarted,

  /// A `saveContent` item needed no download of this job's own (debug;
  /// `index`, `why`: `local` when its content is already whole, `other`
  /// when another caller's download was under way, which this job joins and
  /// never cancels).
  downloadShared,

  /// A `saveContent` item's download completed but its file could not be
  /// leased (warning; `index`, `attempt`: 1 downloads it once more, 2 fails
  /// it `unavailable`).
  leaseMissing,

  /// A `saveContent` batch ran without `TrackedTransfers` in the
  /// composition, so its items, whose content it cannot reach, failed
  /// `unavailable` (warning; `items`).
  trackedTransfersMissing,

  /// A cancel stopped the downloads of a `saveContent` batch (debug; `own`
  /// cancelled, `shared` left running).
  downloadsCancelled;

  @override
  String get category => 'save';
}
