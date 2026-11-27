import 'package:mpx_transfer/src/journal/journal_store.dart';

/// The journal's store on the web: memory for now, so jobs do not survive
/// the tab. [directory] is ignored, as by the bytes cache's open.
JournalStore platformJournalStore(String? directory) => MemoryJournalStore();
