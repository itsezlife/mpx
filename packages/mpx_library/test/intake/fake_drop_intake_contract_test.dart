import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/testing.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('mpx_drop'));
  tearDown(() => directory.deleteSync(recursive: true));

  DropSourceContract.run(() {
    final source = FakeDropSource();
    return DropSourceHarness(
      source: source,
      files: const {'a.png': 3, 'b.mov': 7},
      at: const Offset(40, 50),
      dropFiles: () async => source.drop(at: const Offset(40, 50), const [
        IntakeFile(source: IntakeSource.path('/a.png'), name: 'a.png', size: 3),
        IntakeFile(source: IntakeSource.path('/b.mov'), name: 'b.mov', size: 7),
      ]),
      dropLink: () async => source.drop(const [], refused: 1),
    );
  });

  ClipboardReaderContract.run(() {
    final reader = FakeClipboardReader();
    return ClipboardReaderHarness(
      reader: reader,
      putFile: () async {
        final file = File('${directory.path}/clip.txt')
          ..writeAsStringSync('hello');
        reader.files = [(await IntakeFiles.fromPath(file.path))!];
      },
      putImage: (bytes) async => reader.files = [
        await IntakeFiles.fromBytes(
          bytes,
          mimeType: 'image/png',
          directory: directory.path,
        ),
      ],
      clear: () async => reader.files = const [],
    );
  });
}
