import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of the media saver, category `save`: a batch
/// started, moving, each item's end, and the batch's end.
///
/// Every event of a batch carries the `SaveJob`'s id as its `jobId`; an item's events
/// carry `index`, its place in the batch. No field carries user content: no
/// file name, path, album or sub-folder name, and no platform ref; a MIME
/// type goes by its top-level type only (`image`, `video` or `other`).
enum SaveOp implements DiagnosticOp {
  /// A batch began (info; `items`, `destination`, `named` when the host set
  /// an album or a sub-folder, `platform`, and the item count per kind:
  /// `photos`, `videos`, `animations`, `files`).
  jobStarted,

  /// The batch moved (trace; `fraction`, `stage`).
  progress,

  /// An item was saved (debug; `index`, `kind`, `mime`, `bytes` when
  /// known, `ms` since the batch began, `renamed`).
  itemSaved,

  /// An item failed (warning; `index`, `reason`, `code` when the platform
  /// gave one).
  itemFailed,

  /// An item was cancelled (debug; `index`, `stage`).
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

  /// The system prompt for the access saving needs was shown (info;
  /// `access`: `addOnly`, `readWrite` or `legacyWrite`, `result`: the
  /// `SaveAccess` it left). A host's own request carries no `jobId`.
  accessRequested,

  /// A batch to the gallery failed every item `unavailable` because the build
  /// lacks the code for it (warning; `destination`, `named`, `define`: the
  /// missing build define's name).
  defineMissing;

  @override
  String get category => 'save';
}
