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
  const JournalPlatform({
    required this.store,
    this.sourceCopies,
    this.unloadWarning,
  });

  /// Where the journal's bytes are.
  final JournalStore store;

  /// Where upload sources are copied at job creation; null where a source
  /// is a file that survives by itself (the VM).
  final UploadSourceCopies? sourceCopies;

  /// The warning before the page is left; null where there is no page.
  final UnloadWarning? unloadWarning;
}
