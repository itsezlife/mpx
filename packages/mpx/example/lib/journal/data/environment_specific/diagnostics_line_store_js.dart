import 'package:mpx_example/journal/data/diagnostics_line_store.dart';

/// The web hook: no files, so the journal lasts as long as the page.
Future<DiagnosticsLineStore> $openDiagnosticsLineStore({
  required String? directory,
  required int capBytes,
}) async => MemoryDiagnosticsLineStore();
