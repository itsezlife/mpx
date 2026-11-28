import 'package:flutter/foundation.dart' show debugPrint;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/journal/data/diagnostics_journal.dart';
import 'package:mpx_example/journal/data/diagnostics_line_store.dart';
import 'package:mpx_example/journal/data/environment_specific/host_environment.dart'
    as environment_specific;

/// Starts the process's journal: the composition root of every example app
/// calls [start] once, before the media stack, and reads [journal] after.
abstract final class JournalHost {
  /// The journal [start] made; null before it ran.
  static DiagnosticsJournal? get journal => _journal;
  static DiagnosticsJournal? _journal;

  /// Opens the journal in a folder named [name] of the cache directory
  /// (memory on the web, and when the folder cannot be opened), routes
  /// `MpxDiagnostics.current` into it and restores the previous run's tail.
  ///
  /// The bytes cache's events arrive through the same policy: `MpxStack`
  /// bridges them into `MpxDiagnostics.current` as category `cache`.
  static Future<DiagnosticsJournal> start({
    required String name,
    int capBytes = DiagnosticsJournal.defaultCapBytes,
  }) async {
    DiagnosticsLineStore store;
    try {
      store = await DiagnosticsLineStore.open(
        directory: environment_specific.$journalDirectoryPath(name),
        capBytes: capBytes,
      );
    } on Object catch (error) {
      debugPrint('The journal store did not open ($error); using memory.');
      store = MemoryDiagnosticsLineStore();
    }
    final journal = DiagnosticsJournal(store: store, capBytes: capBytes);
    _journal = journal;
    MpxDiagnostics.current = journal.mpxDiagnostics;
    await journal.restore();
    return journal;
  }
}
