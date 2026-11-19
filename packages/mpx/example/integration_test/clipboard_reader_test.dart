/// `ClipboardReaderContract` over the native clipboard reader
/// (`flutter test integration_test/clipboard_reader_test.dart -d macos`).
/// It replaces what the system clipboard holds.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';
import 'package:super_clipboard/super_clipboard.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final directory = Directory.systemTemp.createTempSync('mpx_clipboard');

  Future<void> put(DataWriterItem item) =>
      SystemClipboard.instance!.write([item]);

  ClipboardReaderContract.run(
    () => ClipboardReaderHarness(
      reader: PlatformIntake.clipboardReader()!,
      putFile: () async {
        final file = File('${directory.path}/clip.txt')
          ..writeAsStringSync('hello');
        await put(DataWriterItem()..add(Formats.fileUri(file.uri)));
      },
      putImage: (bytes) => put(DataWriterItem()..add(Formats.png(bytes))),
      clear: () => put(DataWriterItem()..add(Formats.plainText('mpx'))),
    ),
  );
}
