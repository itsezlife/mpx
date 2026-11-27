import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/journal/journal_platform.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/opfs_journal_storage.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:mpx_transfer/src/journal/window_unload_warning.dart';
import 'package:web/web.dart' as web;

/// The journal of a page: in OPFS beside the bytes cache's store, upload
/// sources copied there, and the page's warning before it is left.
///
/// Where the page has no OPFS the journal is in memory and no source is
/// copied, so nothing survives the tab; the journal's `opened` event names
/// the memory store. An OPFS that is there but refuses to open is reported
/// (`journal` `writeFailed`) and falls back the same way. [directory] is
/// ignored, as by the bytes cache's open. [root] gives the OPFS root, for
/// tests; given, the page counts as having OPFS.
Future<JournalPlatform> openJournalPlatform(
  String? directory, {
  Future<web.FileSystemDirectoryHandle> Function()? root,
}) async {
  if (root != null || _hasOpfs()) {
    try {
      final (store, copies) = await OpfsJournalStorage.open(root: root);
      return JournalPlatform(
        store: store,
        sourceCopies: copies,
        unloadWarning: WindowUnloadWarning(),
      );
    } on Object catch (error, stackTrace) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.error,
        JournalOp.writeFailed,
        fields: () => {'code': OpfsJournalStorage.errorCode(error)},
        stackTrace: stackTrace,
      );
    }
  }
  return JournalPlatform(
    store: MemoryJournalStore(),
    sourceCopies: const NoUploadSourceCopies(),
    unloadWarning: WindowUnloadWarning(),
  );
}

/// Whether the page has an origin private file system: a secure context
/// whose storage manager can give its root.
bool _hasOpfs() {
  final navigator = web.window.navigator as JSObject;
  if (!navigator.has('storage')) return false;
  return (navigator['storage']! as JSObject).has('getDirectory');
}
