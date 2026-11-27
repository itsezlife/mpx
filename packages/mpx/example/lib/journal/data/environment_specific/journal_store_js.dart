import 'package:mpx_example/journal/data/journal_store.dart';

/// The web hook: no files, so the journal lasts as long as the page.
Future<JournalStore> $openJournalStore({
  required String? directory,
  required int capBytes,
}) async => MemoryJournalStore();
