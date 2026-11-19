import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/src/intake/drop_intake.dart';

/// What a [DropSource] contract run needs. A real drag needs a person or a
/// driver, so the harness performs it: a fake scripts it, a device run
/// drags the files.
final class DropSourceHarness {
  /// Creates a harness.
  const DropSourceHarness({
    required this.source,
    required this.dropFiles,
    required this.dropLink,
    required this.files,
  });

  /// The source under test.
  final DropSource source;

  /// Drags [files] over the window and drops them.
  final Future<void> Function() dropFiles;

  /// Drags a link (no local file) over the window and drops it.
  final Future<void> Function() dropLink;

  /// The names and sizes of the files [dropFiles] drops.
  final Map<String, int> files;
}

/// The contract every [DropSource] meets.
abstract final class DropSourceContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(DropSourceHarness Function() create) {
    group('DropSource contract', () {
      late DropSourceHarness harness;
      setUp(() => harness = create());

      Future<List<DropEvent>> record(Future<void> Function() drag) async {
        final events = <DropEvent>[];
        final subscription = harness.source.events.listen(events.add);
        await drag();
        await pumpEventQueue();
        await subscription.cancel();
        return events;
      }

      test('a drop of files enters, ends with the local files', () async {
        final events = await record(harness.dropFiles);
        expect(events.first, isA<DropEnter>());
        expect((events.first as DropEnter).offer.hasFiles, isTrue);
        final done = events.whereType<DropDone>().single;
        expect(events.last, same(done));
        expect({
          for (final file in done.files) file.name: file.size,
        }, harness.files);
        expect(done.refused, 0);
      });

      test('a drop of a link refuses it', () async {
        final events = await record(harness.dropLink);
        final done = events.whereType<DropDone>().single;
        expect(done.files, isEmpty);
        expect(done.refused, greaterThan(0));
      });

      test('wrap keeps the child', () {
        const child = SizedBox(key: ValueKey('child'));
        final wrapped = harness.source.wrap(child);
        expect(
          identical(wrapped, child) ||
              (wrapped is SingleChildRenderObjectWidget &&
                  identical(wrapped.child, child)),
          isTrue,
        );
      });
    });
  }
}

/// What a [ClipboardReader] contract run needs: ways to put a file, image
/// data or nothing on the clipboard.
final class ClipboardReaderHarness {
  /// Creates a harness.
  const ClipboardReaderHarness({
    required this.reader,
    required this.putFile,
    required this.putImage,
    required this.clear,
  });

  /// The reader under test.
  final ClipboardReader reader;

  /// Puts a local file named `clip.txt` of 5 bytes on the clipboard.
  final Future<void> Function() putFile;

  /// Puts PNG [bytes] on the clipboard as image data.
  final Future<void> Function(Uint8List bytes) putImage;

  /// Empties the clipboard of files and images.
  final Future<void> Function() clear;
}

/// The contract every [ClipboardReader] meets.
abstract final class ClipboardReaderContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(ClipboardReaderHarness Function() create) {
    group('ClipboardReader contract', () {
      late ClipboardReaderHarness harness;
      setUp(() => harness = create());

      test('a file on the clipboard comes back as that file', () async {
        await harness.putFile();
        final files = await harness.reader.readFiles();
        expect(files.single.name, 'clip.txt');
        expect(files.single.size, 5);
      });

      test('image data comes back as a file of its type', () async {
        final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
        await harness.putImage(png);
        final file = (await harness.reader.readFiles()).single;
        expect(file.mimeType, 'image/png');
        expect(file.size, png.length);
      });

      test('an empty clipboard answers nothing', () async {
        await harness.clear();
        expect(await harness.reader.readFiles(), isEmpty);
      });
    });
  }
}
