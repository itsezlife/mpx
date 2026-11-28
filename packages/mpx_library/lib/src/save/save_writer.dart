import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_result.dart';

/// One item as the runner hands it to a [SaveWriter], after the rules every
/// platform shares are applied: its [kind] is the one to file it as (a
/// `file` sent to the gallery already routed by its MIME type), and [move]
/// is false for a leased file whatever the caller asked.
final class SaveWrite {
  /// The write of [item], the [index]th of its batch.
  const SaveWrite({
    required this.jobId,
    required this.index,
    required this.item,
    required this.kind,
    required this.move,
    required this.destination,
  });

  /// The id of the item's job, for the writer's own diagnostics events.
  final String jobId;

  /// The item's place in its batch.
  final int index;

  /// The item as the caller gave it.
  final SaveItem item;

  /// What to file it as.
  final SaveItemKind kind;

  /// Whether the writer may move the source instead of copying it.
  final bool move;

  /// Where it goes.
  final SaveDestination destination;
}

/// The platform half of a `MediaSaver`: what differs per platform. The
/// runner (`SaveJobRunner`) holds what does not: one job per batch, routing
/// by MIME type, no move of a leased file, lease release, progress,
/// cancel and diagnostics.
///
/// Two shapes, by how the platform writes a batch: [SaveWriter$PerItem]
/// writes one item after another and can stop between and inside them;
/// [SaveWriter$Block] writes the whole batch in one atomic block (a Photos
/// change block), which cannot be stopped once begun.
sealed class SaveWriter {
  const SaveWriter();

  /// The platform's name for diagnostics: `android`, `ios`, `macos`,
  /// `windows`, `linux`, `web`, or a test's own.
  String get platform;

  /// The writer that writes a batch to [destination] in this one's place,
  /// or null when this one does: a platform that writes destinations in
  /// different shapes (macOS: Photos as one block, files item by item). The
  /// runner asks once per batch, before anything else, and runs the batch
  /// on the writer it gets.
  SaveWriter? delegateFor(SaveDestination destination) => null;

  /// Checked once per batch before anything is written; a failed result
  /// fails every item of the batch with it (denied access, no adapter, a
  /// build without the code). Null lets the batch through. A
  /// `saveContent` batch is admitted before its contents are downloaded, so
  /// [items] is empty for it.
  Future<SaveResult$Failed?> admit(
    String jobId,
    SaveDestination destination,
    List<SaveItem> items,
  );
}

/// A [SaveWriter] that writes item by item.
abstract base class SaveWriter$PerItem extends SaveWriter {
  /// A writer.
  const SaveWriter$PerItem();

  /// Writes [write], reporting the bytes written through [onProgress], and
  /// stops on [cancellation] with [SaveResult.cancelled]. A throw counts as
  /// [SaveFailure.unavailable].
  ///
  /// [SaveResult.cancelled] ends the batch, not only its item: the runner
  /// cancels the job, so the items after it end cancelled unwritten. That is
  /// how a writer reports a picker the user dismissed (the user said no to
  /// the batch). A writer never cancels [cancellation] itself, which is the
  /// job's and would skip what the job's cancel does.
  Future<SaveResult> write(
    SaveWrite write, {
    required FetchProgress onProgress,
    required CancellationToken cancellation,
  });
}

/// A [SaveWriter] that writes the batch as one atomic block.
abstract base class SaveWriter$Block extends SaveWriter {
  /// A writer.
  const SaveWriter$Block();

  /// Writes every one of [writes] in one block, reporting the block's
  /// fraction done (0 to 1) through [onProgress]; one result per write, in
  /// order. The block is atomic: when any result is a failure the runner
  /// fails every item with it. A throw fails every item
  /// [SaveFailure.unavailable].
  Future<List<SaveResult>> writeBlock(
    List<SaveWrite> writes, {
    required void Function(double fraction) onProgress,
  });
}
