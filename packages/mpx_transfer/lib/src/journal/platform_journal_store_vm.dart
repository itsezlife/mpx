import 'dart:io';

import 'package:mpx_transfer/src/journal/file_journal_store.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';

/// The journal's store on the VM: files in `mpx_transfer` below
/// [directory], the bytes cache's directory.
///
/// Throws an [ArgumentError] when [directory] is missing, as the bytes
/// cache's open does: that is wiring, not a storage failure.
JournalStore platformJournalStore(String? directory) => switch (directory) {
  final root? when root.isNotEmpty => FileJournalStore(
    '$root${Platform.pathSeparator}mpx_transfer',
  ),
  _ => throw ArgumentError.value(directory, 'directory', 'required on VM'),
};
