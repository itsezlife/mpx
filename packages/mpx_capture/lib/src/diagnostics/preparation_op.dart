import 'package:mpx_core/mpx_core.dart';

/// The diagnostics operations of media preparation, category `preparation`:
/// an item queued, started, moving, and how it ended.
///
/// Every event carries `n`, a number unique to the item within its
/// preparer, and `kind` (`photo`, `video` or `file`). No field carries user
/// content: no path, no file name; sizes are byte counts.
enum PreparationOp implements DiagnosticOp {
  /// An item was accepted (debug; `waitingForVideoSlot` when it is a video
  /// and the video limit is taken).
  queued,

  /// An item took its slots and began (debug; `waitedMs` since queued).
  started,

  /// An item moved (trace; `fraction`).
  progress,

  /// An item produced its file (info; `bytes`, `ms` since queued,
  /// `original` when the input goes as it is).
  finished,

  /// An item failed (error; `code`, `ms`).
  failed,

  /// An item was cancelled (info; `ms`).
  cancelled;

  @override
  String get category => 'preparation';
}
