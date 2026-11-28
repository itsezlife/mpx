/// Where the diagnostics journal keeps its lines between runs.
library;

import 'package:mpx_example/journal/data/environment_specific/diagnostics_line_store.dart'
    as environment_specific;

/// The lines of the diagnostics journal, oldest first, kept where they
/// survive the process (a file) or only for this run (memory).
///
/// [append] is synchronous on purpose: the journal writes a warning or an
/// error before the call that reported it returns, so a kill a moment later
/// still finds it on disk. An asynchronous write could still be queued when
/// the process dies.
abstract interface class DiagnosticsLineStore {
  /// A store on disk under [directory], holding about [capBytes] of lines,
  /// or one in memory on the web and when [directory] is null.
  static Future<DiagnosticsLineStore> open({
    required String? directory,
    required int capBytes,
  }) => environment_specific.$openDiagnosticsLineStore(
    directory: directory,
    capBytes: capBytes,
  );

  /// Whether the lines outlive the process.
  bool get isPersistent;

  /// Every line kept, oldest first.
  Future<List<String>> read();

  /// Adds [lines] after the last one, dropping the oldest past the store's
  /// cap. Throws when the write fails.
  void append(List<String> lines);

  /// Releases the store; nothing is appended after.
  Future<void> close();
}

/// A [DiagnosticsLineStore] in memory: the web's, and the tests', which open a
/// second journal over the same store to stand for a restart.
final class MemoryDiagnosticsLineStore implements DiagnosticsLineStore {
  /// An empty store.
  MemoryDiagnosticsLineStore();

  final List<String> _lines = [];

  /// The lines appended so far, oldest first.
  List<String> get lines => List.unmodifiable(_lines);

  @override
  bool get isPersistent => false;

  @override
  Future<List<String>> read() async => List.of(_lines);

  @override
  void append(List<String> lines) => _lines.addAll(lines);

  @override
  Future<void> close() async {}
}
