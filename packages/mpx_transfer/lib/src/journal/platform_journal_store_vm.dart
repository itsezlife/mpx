import 'dart:io';

import 'package:mpx_transfer/src/journal/file_journal_store.dart';
import 'package:mpx_transfer/src/journal/journal_platform.dart';

/// The journal on the VM: files in `mpx_transfer` below [directory], the
/// bytes cache's directory, with the reuse table's files beside them. Upload sources are files that survive by
/// themselves, so none is copied, and there is no page to warn.
///
/// Throws an [ArgumentError] when [directory] is missing, as the bytes
/// cache's open does: that is wiring, not a storage failure.
Future<JournalPlatform> openJournalPlatform(String? directory) async =>
    switch (directory) {
      final root? when root.isNotEmpty => JournalPlatform(
        store: FileJournalStore(_inRoot(root)),
        reuseStore: FileJournalStore(_inRoot(root), name: 'reuse'),
      ),
      _ => throw ArgumentError.value(directory, 'directory', 'required on VM'),
    };

String _inRoot(String root) => '$root${Platform.pathSeparator}mpx_transfer';
