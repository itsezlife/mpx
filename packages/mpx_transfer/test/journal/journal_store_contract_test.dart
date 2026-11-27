import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_transfer/src/journal/file_journal_store.dart';
import 'package:mpx_transfer/testing.dart';

void main() {
  JournalStoreContract.run('memory', () {
    final store = MemoryJournalStore();
    return () => store;
  });

  JournalStoreContract.run('file', () {
    final directory = Directory.systemTemp.createTempSync('mpx_journal_');
    addTearDown(() => directory.delete(recursive: true));
    // A new store over the same files at each start, as a new process
    // would open them.
    return () => FileJournalStore('${directory.path}/journal');
  });

  UploadSourceCopiesContract.run('fake', () {
    final copies = FakeUploadSourceCopies();
    return () async => copies;
  });
}
