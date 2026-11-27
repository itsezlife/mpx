import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/unload_warning.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';

/// What a platform gives the engine to outlive the process: where the
/// journal is, where upload sources are copied, and the page's warning
/// before it is left.
///
/// Internal to the package.
final class JournalPlatform {
  /// The parts of one platform.
  JournalPlatform({
    required this.store,
    JournalStore? reuseStore,
    this.sourceCopies,
    this.unloadWarning,
  }) : reuseStore = reuseStore ?? MemoryJournalStore();

  /// Where the journal's bytes are.
  final JournalStore store;

  /// Where the reuse table's bytes are: beside the journal's, in the same
  /// kind of storage.
  final JournalStore reuseStore;

  /// Where upload sources are copied at job creation; null where a source
  /// is a file that survives by itself (the VM).
  final UploadSourceCopies? sourceCopies;

  /// The warning before the page is left; null where there is no page.
  final UnloadWarning? unloadWarning;
}
