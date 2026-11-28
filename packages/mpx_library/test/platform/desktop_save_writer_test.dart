import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/platform/save_file_copy.dart';
import 'package:mpx_library/src/platform/save_platform.dart';
import 'package:mpx_library/testing.dart';

/// The user's folders as temporary directories, one per [DesktopFolder];
/// a folder in [missing] is one the system names none for.
final class _TempFolders implements DesktopFolders {
  _TempFolders(this.root, {this.missing = const {}});

  final Directory root;
  final Set<DesktopFolder> missing;

  String path(DesktopFolder folder) =>
      '${root.path}${Platform.pathSeparator}${folder.name}';

  @override
  Future<String?> pathOf(DesktopFolder folder) async =>
      missing.contains(folder) ? null : path(folder);
}

/// A sandbox per test: a source directory, the folders, and a saver over a
/// desktop writer for [os].
final class _Desk {
  _Desk(
    this.os, {
    Set<DesktopFolder> missing = const {},
    Future<String?> Function(String suggestedName)? pickLocation,
    int chunkSize = 1 << 20,
    SaveFileCopier? copy,
  }) : root = Directory.systemTemp.createTempSync('mpx_desktop_save_') {
    addTearDown(() => root.deleteSync(recursive: true));
    folders = _TempFolders(
      Directory('${root.path}${Platform.pathSeparator}user')..createSync(),
      missing: missing,
    );
    sources = Directory('${root.path}${Platform.pathSeparator}sources')
      ..createSync();
    saver = PlatformMediaSaver.over(
      DesktopSaveWriter(
        os,
        folders: folders,
        pickLocation: pickLocation ?? (_) async => null,
        chunkSize: chunkSize,
        copy: copy,
      ),
      platform: switch (os) {
        DesktopPlatform.windows => SavePlatform.windows,
        DesktopPlatform.linux => SavePlatform.linux,
        // The files writer alone: no Photos access, which the macOS
        // writer's own tests cover.
        DesktopPlatform.macos => SavePlatform.other,
      },
    );
  }

  final DesktopPlatform os;
  final Directory root;
  late final _TempFolders folders;
  late final Directory sources;
  late final MediaSaver saver;
  var _next = 0;

  /// A fresh source file holding [bytes] (a few bytes by default).
  String source([List<int>? bytes]) {
    final file = File(
      '${sources.path}${Platform.pathSeparator}source-${_next++}',
    )..writeAsBytesSync(bytes ?? [1, 2, 3, 4, 5]);
    return file.path;
  }

  String inFolder(DesktopFolder folder, String relative) =>
      '${folders.path(folder)}${Platform.pathSeparator}$relative';

  List<String> namesIn(String directory) => [
    for (final entry in Directory(directory).listSync())
      entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
  ]..sort();
}

String _sep(String relative) =>
    relative.replaceAll('/', Platform.pathSeparator);

void main() {
  for (final os in DesktopPlatform.values) {
    group(os.name, () {
      MediaSaverContract.run(() {
        final desk = _Desk(os);
        return MediaSaverHarness(saver: desk.saver, file: (_) => desk.source());
      });

      MediaSaverContract.run(() {
        final desk = _Desk(os);
        return MediaSaverHarness(
          saver: desk.saver,
          file: (_) => desk.source(),
          destination: const SaveDestination.downloads(subfolder: 'Host'),
        );
      });
    });
  }

  group('folders', () {
    late RecordingDiagnostics diagnostics;
    setUp(() => diagnostics = RecordingDiagnostics.install());

    test('downloads go into the sub-folder, made when missing', () async {
      final desk = _Desk(DesktopPlatform.linux);
      final results = await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: 'report.pdf',
          mimeType: 'application/pdf',
          kind: SaveItemKind.file,
        ),
      ], const SaveDestination.downloads(subfolder: 'Host App')).results;

      final path = desk.inFolder(
        DesktopFolder.downloads,
        _sep('Host App/report.pdf'),
      );
      expect(results, [SaveResult.saved(path)]);
      expect(File(path).readAsBytesSync(), [1, 2, 3, 4, 5]);
    });

    test('the gallery files photos and GIFs in Pictures, videos and '
        'video animations in Videos, in the album', () async {
      final desk = _Desk(DesktopPlatform.windows);
      final results = await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
        SaveItem.file(
          desk.source(),
          name: 'b.mp4',
          mimeType: 'video/mp4',
          kind: SaveItemKind.video,
        ),
        SaveItem.file(
          desk.source(),
          name: 'c.gif',
          mimeType: 'image/gif',
          kind: SaveItemKind.animation,
        ),
        SaveItem.file(
          desk.source(),
          name: 'd.mp4',
          mimeType: 'video/mp4',
          kind: SaveItemKind.animation,
        ),
        SaveItem.file(
          desk.source(),
          name: 'e.webm',
          mimeType: 'video/webm',
          kind: SaveItemKind.file,
        ),
      ], const SaveDestination.gallery(album: 'Album')).results;

      expect(results, everyElement(isA<SaveResult$Saved>()));
      expect(desk.namesIn(desk.inFolder(DesktopFolder.pictures, 'Album')), [
        'a.jpg',
        'c.gif',
      ]);
      expect(desk.namesIn(desk.inFolder(DesktopFolder.videos, 'Album')), [
        'b.mp4',
        'd.mp4',
        'e.webm',
      ]);
    });

    test(
      'a folder the system names none for fails the item unavailable',
      () async {
        final desk = _Desk(
          DesktopPlatform.linux,
          missing: {DesktopFolder.downloads},
        );
        final results = await desk.saver.save([
          SaveItem.file(
            desk.source(),
            name: 'a.zip',
            mimeType: 'application/zip',
            kind: SaveItemKind.file,
          ),
        ], const SaveDestination.downloads()).results;

        const failure = SaveResult.failed(
          SaveFailure.unavailable,
          code: 'noFolder',
        );
        expect(results, [failure]);
        expect(diagnostics.whereOp(SaveOp.itemFailed), [
          isMpxEvent(
            fields: allOf(
              containsPair('reason', 'unavailable'),
              containsPair('code', 'noFolder'),
            ),
          ),
        ]);
      },
    );
  });

  group('collisions', () {
    late RecordingDiagnostics diagnostics;
    setUp(() => diagnostics = RecordingDiagnostics.install());

    test('a taken name gets " (1)", then " (2)", before the extension; '
        'the item is reported renamed', () async {
      final desk = _Desk(DesktopPlatform.windows);
      final downloads = desk.folders.path(DesktopFolder.downloads);
      Directory(downloads).createSync();
      File(
        '$downloads${Platform.pathSeparator}photo.jpg',
      ).writeAsBytesSync([9]);
      SaveItem photo() => SaveItem.file(
        desk.source(),
        name: 'photo.jpg',
        mimeType: 'image/jpeg',
        kind: SaveItemKind.photo,
      );
      final results = await desk.saver.save([
        photo(),
        photo(),
      ], const SaveDestination.downloads()).results;

      expect(results, [
        SaveResult.saved(
          desk.inFolder(DesktopFolder.downloads, 'photo (1).jpg'),
          renamed: true,
        ),
        SaveResult.saved(
          desk.inFolder(DesktopFolder.downloads, 'photo (2).jpg'),
          renamed: true,
        ),
      ]);
      expect(
        File('$downloads${Platform.pathSeparator}photo.jpg').readAsBytesSync(),
        [9],
        reason: 'the file already there is kept',
      );
      expect(
        diagnostics
            .whereOp(SaveOp.itemSaved)
            .map((e) => (e.fields['renamed'], e.fields['bytes'])),
        [(true, 5), (true, 5)],
      );
    });

    test('numbered names', () {
      expect(DesktopSaveNames.numbered('photo.jpg', 1), 'photo (1).jpg');
      expect(DesktopSaveNames.numbered('README', 2), 'README (2)');
      expect(DesktopSaveNames.numbered('.profile', 1), '.profile (1)');
      expect(
        DesktopSaveNames.numbered('archive.tar.gz', 3),
        'archive.tar (3).gz',
      );
    });

    test('a name never leaves its folder and holds no character a desktop '
        'file system refuses', () {
      expect(DesktopSaveNames.sanitize('../../etc/passwd'), '.._.._etc_passwd');
      expect(
        DesktopSaveNames.sanitize(r'a\b:c*d?e"f<g>h|i'),
        'a_b_c_d_e_f_g_h_i',
      );
      expect(DesktopSaveNames.sanitize('tab\there'), 'tab_here');
      expect(DesktopSaveNames.sanitize('name. '), 'name');
      expect(DesktopSaveNames.sanitize('..'), 'file');
      expect(DesktopSaveNames.sanitize(''), 'file');
      expect(DesktopSaveNames.sanitize('CON.txt'), '_CON.txt');
      expect(DesktopSaveNames.sanitize('photo.jpg'), 'photo.jpg');
    });

    test('a hostile name and sub-folder stay inside Downloads', () async {
      final desk = _Desk(DesktopPlatform.linux);
      final results = await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: '../escape.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      ], const SaveDestination.downloads(subfolder: '../up')).results;

      expect(results, [
        SaveResult.saved(
          desk.inFolder(DesktopFolder.downloads, _sep('.._up/.._escape.jpg')),
        ),
      ]);
    });
  });

  group('file', () {
    setUp(RecordingDiagnostics.install);

    test('the modification time is the item\'s creation date', () async {
      final desk = _Desk(DesktopPlatform.linux);
      final createdAt = DateTime(2024, 5, 17, 10, 30, 12);
      final results = await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
          createdAt: createdAt,
        ),
      ], const SaveDestination.gallery()).results;

      final saved = results.single as SaveResult$Saved;
      expect(File(saved.platformRef!).lastModifiedSync(), createdAt);
    });

    test('without a creation date the file keeps the time of the '
        'save', () async {
      final desk = _Desk(DesktopPlatform.linux);
      final before = DateTime.now().subtract(const Duration(minutes: 1));
      final results = await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      ], const SaveDestination.gallery()).results;

      final saved = results.single as SaveResult$Saved;
      expect(File(saved.platformRef!).lastModifiedSync().isAfter(before), true);
    });

    test('a host file with move is moved into place', () async {
      final desk = _Desk(DesktopPlatform.windows);
      final source = desk.source();
      final results = await desk.saver.save([
        SaveItem.file(
          source,
          name: 'a.mp4',
          mimeType: 'video/mp4',
          kind: SaveItemKind.video,
          move: true,
        ),
      ], const SaveDestination.downloads()).results;

      final path = desk.inFolder(DesktopFolder.downloads, 'a.mp4');
      expect(results, [SaveResult.saved(path)]);
      expect(File(source).existsSync(), false);
      expect(File(path).readAsBytesSync(), [1, 2, 3, 4, 5]);
    });

    test('a leased file is copied and stays with its keeper', () async {
      final desk = _Desk(DesktopPlatform.linux);
      final source = desk.source();
      var released = 0;
      final results = await desk.saver.save([
        SaveItem.leased(
          ContentFileLease(path: source, onRelease: () async => released++),
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
          move: true,
        ),
      ], const SaveDestination.downloads()).results;

      expect(results.single, isA<SaveResult$Saved>());
      expect(File(source).existsSync(), true);
      expect(released, 1);
    });

    test('bytes are written as the file', () async {
      final desk = _Desk(DesktopPlatform.linux);
      final results = await desk.saver.save([
        SaveItem.bytes(
          Uint8List.fromList([7, 8]),
          name: 'note.txt',
          mimeType: 'text/plain',
          kind: SaveItemKind.file,
        ),
      ], const SaveDestination.downloads()).results;

      final path = desk.inFolder(DesktopFolder.downloads, 'note.txt');
      expect(results, [SaveResult.saved(path)]);
      expect(File(path).readAsBytesSync(), [7, 8]);
    });

    test('a source that is gone fails unavailable with the OS code, and '
        'leaves no file behind', () async {
      final desk = _Desk(DesktopPlatform.linux);
      final diagnostics = RecordingDiagnostics.install();
      final results = await desk.saver.save([
        SaveItem.file(
          '${desk.sources.path}${Platform.pathSeparator}gone',
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      ], const SaveDestination.downloads()).results;

      final failure = results.single as SaveResult$Failed;
      expect(failure.reason, SaveFailure.unavailable);
      expect(failure.code, startsWith('os'));
      expect(desk.namesIn(desk.folders.path(DesktopFolder.downloads)), isEmpty);
      expect(
        diagnostics.whereOp(SaveOp.itemFailed).single.fields['code'],
        failure.code,
      );
    });

    test('a cancel mid-copy stops the copy, removes the partial file and '
        'cancels the item', () async {
      final desk = _Desk(DesktopPlatform.windows, chunkSize: 1024);
      final diagnostics = RecordingDiagnostics.install();
      final job = desk.saver.save([
        SaveItem.file(
          desk.source(List.filled(1024 * 256, 1)),
          name: 'big.bin',
          mimeType: 'application/octet-stream',
          kind: SaveItemKind.file,
        ),
      ], const SaveDestination.downloads());
      job.progress.addListener(() {
        if (job.progress.value > 0) job.cancel();
      });

      expect(await job.results, [const SaveResult.cancelled()]);
      expect(desk.namesIn(desk.folders.path(DesktopFolder.downloads)), isEmpty);
      expect(diagnostics.whereOp(SaveOp.itemCancelled), [
        isMpxEvent(fields: containsPair('stage', 'copy')),
      ]);
    });
  });

  group('a write that does not finish leaves nothing', () {
    test('while the copy runs the bytes go into a hidden part file, and the '
        'name holds no partial content', () async {
      late _Desk desk;
      final seen = <List<String>>[];
      final sizes = <int>[];
      desk = _Desk(DesktopPlatform.linux, chunkSize: 1024);
      final job = desk.saver.save([
        SaveItem.file(
          desk.source(List.filled(4096, 1)),
          name: 'big.bin',
          mimeType: 'application/octet-stream',
          kind: SaveItemKind.file,
        ),
      ], const SaveDestination.downloads());
      final downloads = desk.folders.path(DesktopFolder.downloads);
      job.progress.addListener(() {
        if (job.progress.value >= 1 || seen.isNotEmpty) return;
        seen.add(desk.namesIn(downloads));
        sizes.add(
          File(desk.inFolder(DesktopFolder.downloads, 'big.bin')).lengthSync(),
        );
      });

      expect((await job.results).single, isA<SaveResult$Saved>());
      expect(seen.single, ['.big.bin.part', 'big.bin']);
      expect(sizes.single, 0, reason: 'the claim is empty until the end');
      expect(desk.namesIn(downloads), ['big.bin']);
      expect(
        File(desk.inFolder(DesktopFolder.downloads, 'big.bin')).lengthSync(),
        4096,
      );
    });

    test('a copy worker that fails leaves neither the claimed name nor the '
        'part file', () async {
      final desk = _Desk(
        DesktopPlatform.windows,
        copy:
            (
              from,
              to, {
              required onProgress,
              required cancellation,
              chunkSize = 0,
            }) async {
              File(to).writeAsBytesSync([1, 2]);
              throw StateError('the copy worker failed');
            },
      );
      final results = await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      ], const SaveDestination.gallery()).results;

      expect(results, [
        const SaveResult.failed(SaveFailure.unavailable, code: 'throw'),
      ]);
      expect(desk.namesIn(desk.folders.path(DesktopFolder.pictures)), isEmpty);
    });

    test('a file the user picked is removed when its copy fails', () async {
      late _Desk desk;
      desk = _Desk(
        DesktopPlatform.linux,
        pickLocation: (_) async =>
            '${desk.root.path}${Platform.pathSeparator}picked.jpg',
        copy:
            (
              from,
              to, {
              required onProgress,
              required cancellation,
              chunkSize = 0,
            }) async {
              File(to).writeAsBytesSync([1, 2]);
              throw StateError('the copy worker failed');
            },
      );
      await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      ], const SaveDestination.ask()).results;

      expect(
        File(
          '${desk.root.path}${Platform.pathSeparator}picked.jpg',
        ).existsSync(),
        isFalse,
      );
    });

    test('a leftover that will not go is reported by its type and code, '
        'never its path', () async {
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);
      final desk = _Desk(
        DesktopPlatform.linux,
        // A part that turned into a folder with a file in it: removing it
        // as a file fails.
        copy:
            (
              from,
              to, {
              required onProgress,
              required cancellation,
              chunkSize = 0,
            }) async {
              File(
                '$to${Platform.pathSeparator}inside',
              ).createSync(recursive: true);
              throw StateError('the copy worker failed');
            },
      );
      await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: 'secret.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      ], const SaveDestination.downloads()).results;

      expect(reported, isNotEmpty);
      for (final details in reported) {
        expect('${details.exception}', isNot(contains('secret')));
        expect('${details.exception}', isNot(contains(desk.root.path)));
      }
    });
  });

  group('ask', () {
    setUp(RecordingDiagnostics.install);

    test('saves where the user picked, one dialog per item, the name '
        'suggested', () async {
      final asked = <String>[];
      late _Desk desk;
      desk = _Desk(
        DesktopPlatform.linux,
        pickLocation: (suggested) async {
          asked.add(suggested);
          return '${desk.root.path}${Platform.pathSeparator}picked-$suggested';
        },
      );
      final results = await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: 'a.gif',
          mimeType: 'image/gif',
          kind: SaveItemKind.animation,
        ),
        SaveItem.file(
          desk.source(),
          name: 'b.pdf',
          mimeType: 'application/pdf',
          kind: SaveItemKind.file,
        ),
      ], const SaveDestination.ask()).results;

      expect(asked, ['a.gif', 'b.pdf']);
      expect(results, [
        SaveResult.saved(
          '${desk.root.path}${Platform.pathSeparator}picked-a.gif',
        ),
        SaveResult.saved(
          '${desk.root.path}${Platform.pathSeparator}picked-b.pdf',
        ),
      ]);
    });

    test('a file the user picked to replace is replaced', () async {
      late _Desk desk;
      desk = _Desk(
        DesktopPlatform.windows,
        pickLocation: (_) async =>
            '${desk.root.path}${Platform.pathSeparator}existing',
      );
      File(
        '${desk.root.path}${Platform.pathSeparator}existing',
      ).writeAsBytesSync(List.filled(64, 0));
      final results = await desk.saver.save([
        SaveItem.file(
          desk.source(),
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      ], const SaveDestination.ask()).results;

      final saved = results.single as SaveResult$Saved;
      expect(saved.renamed, false);
      expect(File(saved.platformRef!).readAsBytesSync(), [1, 2, 3, 4, 5]);
    });

    test('a dismissed dialog cancels its item and the rest of the batch, '
        'asking no more', () async {
      var asked = 0;
      final desk = _Desk(
        DesktopPlatform.linux,
        pickLocation: (_) async {
          asked++;
          return null;
        },
      );
      SaveItem item() => SaveItem.file(
        desk.source(),
        name: 'a.jpg',
        mimeType: 'image/jpeg',
        kind: SaveItemKind.photo,
      );
      final results = await desk.saver.save([
        item(),
        item(),
      ], const SaveDestination.ask()).results;

      expect(results, [
        const SaveResult.cancelled(),
        const SaveResult.cancelled(),
      ]);
      expect(asked, 1);
    });
  });

  group('errors', () {
    test('OS error codes map to the failure they mean', () {
      const windows = DesktopPlatform.windows;
      const linux = DesktopPlatform.linux;
      expect(windows.failureOf(5), SaveFailure.accessDenied);
      expect(windows.failureOf(112), SaveFailure.noSpace);
      expect(windows.failureOf(39), SaveFailure.noSpace);
      expect(windows.failureOf(2), SaveFailure.unavailable);
      expect(linux.failureOf(13), SaveFailure.accessDenied);
      expect(linux.failureOf(1), SaveFailure.accessDenied);
      expect(linux.failureOf(30), SaveFailure.accessDenied);
      expect(linux.failureOf(28), SaveFailure.noSpace);
      expect(linux.failureOf(122), SaveFailure.noSpace);
      expect(linux.failureOf(2), SaveFailure.unavailable);
    });

    test('a file system failure becomes a failed result with its code', () {
      expect(
        DesktopPlatform.linux.resultOf(
          const FileSystemException('write', 'x', OSError('', 28)),
        ),
        const SaveResult.failed(SaveFailure.noSpace, code: 'os28'),
      );
      expect(
        DesktopPlatform.windows.resultOf(const FileSystemException('write')),
        const SaveResult.failed(SaveFailure.unavailable, code: 'io'),
      );
    });
  });
}
