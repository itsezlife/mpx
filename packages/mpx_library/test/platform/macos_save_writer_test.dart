import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/src/platform/apple_save_writer.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/platform/macos_home_folders.dart';
import 'package:mpx_library/src/platform/platform_save_access.dart';
import 'package:mpx_library/src/platform/save_block_codec.dart';
import 'package:mpx_library/testing.dart';

const _methods = MethodChannel('test.mpx.library/macos-save');

/// The native side of the save on macOS, over the plugin's method channel:
/// the save access, and one `saveBlock` per gallery batch.
final class _FakeMac {
  /// The access status the gallery reads (`saveAccess`).
  String status = 'authorized';

  /// The block's answer; null saves every entry with a ref of its own.
  SaveBlockAnswer? answer;

  final List<SaveBlockRequest> blocks = [];

  static const _requests = SaveBlockRequestCodec();
  static const _answers = SaveBlockAnswerCodec();

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'saveAccess' || 'requestSaveAccess':
        final arguments = call.arguments as Map<Object?, Object?>;
        final gallery = arguments['destination'] == 'gallery';
        return {
          'scope': gallery ? 'addOnly' : 'none',
          'status': gallery ? status : 'authorized',
        };
      case 'saveBlock':
        final request = _requests.decode(
          (call.arguments as Map<Object?, Object?>).cast(),
        );
        blocks.add(request);
        return _answers.encode(
          answer ??
              SaveBlockAnswer$Saved([
                for (var i = 0; i < request.entries.length; i++)
                  SaveBlockSaved('ref-${blocks.length}-$i'),
              ]),
        );
    }
    return null;
  }
}

/// The user's folders as temporary directories.
final class _TempFolders implements DesktopFolders {
  _TempFolders(this.root);

  final Directory root;

  String path(DesktopFolder folder) =>
      '${root.path}${Platform.pathSeparator}${folder.name}';

  @override
  Future<String?> pathOf(DesktopFolder folder) async => path(folder);
}

/// A sandbox per test: sources, the folders, the native fake, and a saver
/// over the macOS writer.
final class _Mac {
  _Mac({
    Future<String?> Function(String suggestedName)? pickLocation,
    this.transfers,
  }) : root = Directory.systemTemp.createTempSync('mpx_macos_save_') {
    addTearDown(() => root.deleteSync(recursive: true));
    folders = _TempFolders(Directory('${root.path}/user')..createSync());
    sources = Directory('${root.path}/sources')..createSync();
    _pickLocation = pickLocation ?? (_) async => null;
    saver = saverWith(transfers);
  }

  final Directory root;
  final FakeTrackedTransfers? transfers;
  late final _TempFolders folders;
  late final Directory sources;
  late final Future<String?> Function(String suggestedName) _pickLocation;
  late final MediaSaver saver;

  /// A saver over the same folders and panel with [transfers].
  MediaSaver saverWith(TrackedTransfers? transfers) => PlatformMediaSaver.over(
    AppleSaveWriter.macos(
      _methods,
      access: const PlatformSaveAccess(
        _methods,
        platform: TargetPlatform.macOS,
      ),
      folders: folders,
      pickLocation: _pickLocation,
    ),
    methods: _methods,
    transfers: transfers,
  );

  /// The contract's harness, saving to [destination].
  MediaSaverHarness harness(
    SaveDestination destination, {
    String Function(int index)? file,
  }) => MediaSaverHarness(
    saver: saver,
    transfers: transfers,
    withoutTransfers: () => saverWith(null),
    file: file ?? (_) => source(),
    destination: destination,
  );
  var _next = 0;

  String source([List<int>? bytes]) {
    final file = File('${sources.path}/source-${_next++}')
      ..writeAsBytesSync(bytes ?? [1, 2, 3, 4, 5]);
    return file.path;
  }

  String downloads(String relative) =>
      '${folders.path(DesktopFolder.downloads)}/$relative';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _FakeMac mac;

  setUp(() {
    mac = _FakeMac();
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(_methods, mac.handle);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_methods, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('contract', () {
    group('to gallery', () {
      MediaSaverContract.run(() {
        final harness = _Mac(transfers: FakeTrackedTransfers()).harness(
          const SaveDestination.gallery(),
          file: (index) => '/cache/source-$index',
        );
        return MediaSaverHarness(
          saver: harness.saver,
          transfers: harness.transfers,
          withoutTransfers: harness.withoutTransfers,
          file: harness.file,
          changeBlock: true,
          denyAccess: () => mac.status = 'denied',
          failBlock: () => mac.answer = const SaveBlockAnswer$Failed(
            domain: 'photos',
            code: '3305',
          ),
        );
      });
    });

    group('to downloads', () {
      MediaSaverContract.run(
        () => _Mac(
          transfers: FakeTrackedTransfers(),
        ).harness(const SaveDestination.downloads(subfolder: 'Host')),
      );
    });

    group('to ask', () {
      MediaSaverContract.run(() {
        late _Mac desk;
        var picked = 0;
        desk = _Mac(
          transfers: FakeTrackedTransfers(),
          pickLocation: (name) async =>
              '${desk.root.path}/picked-${picked++}-$name',
        );
        return desk.harness(const SaveDestination.ask());
      });
    });
  });

  SaveItem photo(_Mac desk, {String name = 'photo.jpg', DateTime? createdAt}) =>
      SaveItem.file(
        desk.source(),
        name: name,
        mimeType: 'image/jpeg',
        kind: SaveItemKind.photo,
        createdAt: createdAt,
      );

  test('a gallery batch is one Photos block, reported for macOS', () async {
    final diagnostics = RecordingDiagnostics.install();
    final desk = _Mac();
    final job = desk.saver.save([
      photo(desk),
      photo(desk),
    ], const SaveDestination.gallery());

    expect(await job.results, const [
      SaveResult.saved('ref-1-0'),
      SaveResult.saved('ref-1-1'),
    ]);
    expect(mac.blocks.single.entries, hasLength(2));
    expect(diagnostics.whereOp(SaveOp.jobStarted), [
      isMpxEvent(fields: containsPair('platform', 'macos')),
    ]);
    expect(diagnostics.whereOp(SaveOp.changeBlock), [
      isMpxEvent(
        jobId: job.id,
        fields: equals({'items': 2, 'result': 'saved'}),
      ),
    ]);
  });

  group('downloads', () {
    late RecordingDiagnostics diagnostics;
    setUp(() => diagnostics = RecordingDiagnostics.install());

    test('go into the sub-folder of Downloads, file by file, with no '
        'native block', () async {
      final desk = _Mac();
      final job = desk.saver.save([
        photo(desk),
      ], const SaveDestination.downloads(subfolder: 'Host'));

      expect(await job.results, [
        SaveResult.saved(desk.downloads('Host/photo.jpg')),
      ]);
      expect(File(desk.downloads('Host/photo.jpg')).readAsBytesSync(), [
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(mac.blocks, isEmpty);
      expect(diagnostics.whereOp(SaveOp.changeBlock), isEmpty);
      expect(diagnostics.whereOp(SaveOp.jobStarted), [
        isMpxEvent(fields: containsPair('platform', 'macos')),
      ]);
    });

    test('a taken name appends " (1)" and is reported renamed', () async {
      final desk = _Mac();
      Directory(desk.downloads('')).createSync();
      File(desk.downloads('photo.jpg')).writeAsBytesSync([9]);
      final results = await desk.saver.save([
        photo(desk),
      ], const SaveDestination.downloads()).results;

      expect(results, [
        SaveResult.saved(desk.downloads('photo (1).jpg'), renamed: true),
      ]);
      expect(File(desk.downloads('photo.jpg')).readAsBytesSync(), [9]);
      expect(
        diagnostics.whereOp(SaveOp.itemSaved).map((e) => e.fields['renamed']),
        [true],
      );
    });

    test('the modification time is the item\'s creation date', () async {
      final desk = _Mac();
      final createdAt = DateTime(2024, 3, 9, 10, 30);
      await desk.saver.save([
        photo(desk, createdAt: createdAt),
      ], const SaveDestination.downloads()).results;

      expect(File(desk.downloads('photo.jpg')).lastModifiedSync(), createdAt);
    });

    test('a GIF animation is written as is', () async {
      final desk = _Mac();
      const gif = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61];
      final results = await desk.saver.save([
        SaveItem.file(
          desk.source(gif),
          name: 'loop.gif',
          mimeType: 'image/gif',
          kind: SaveItemKind.animation,
        ),
      ], const SaveDestination.downloads()).results;

      expect(results, [SaveResult.saved(desk.downloads('loop.gif'))]);
      expect(File(desk.downloads('loop.gif')).readAsBytesSync(), gif);
    });

    test('a source that is gone fails with the OS code', () async {
      final desk = _Mac();
      final results = await desk.saver.save([
        const SaveItem.file(
          '/nowhere/gone',
          name: 'gone.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      ], const SaveDestination.downloads()).results;

      expect(results, [
        const SaveResult.failed(SaveFailure.unavailable, code: 'os2'),
      ]);
      expect(diagnostics.whereOp(SaveOp.itemFailed), [
        isMpxEvent(fields: containsPair('code', 'os2')),
      ]);
    });
  });

  group('ask', () {
    setUp(RecordingDiagnostics.install);

    test('one save panel per item, the item\'s name suggested', () async {
      final asked = <String>[];
      late _Mac desk;
      desk = _Mac(
        pickLocation: (name) async {
          asked.add(name);
          return '${desk.root.path}/picked-$name';
        },
      );
      final results = await desk.saver.save([
        photo(desk, name: 'a.jpg'),
        SaveItem.file(
          desk.source(),
          name: 'b.gif',
          mimeType: 'image/gif',
          kind: SaveItemKind.animation,
        ),
      ], const SaveDestination.ask()).results;

      expect(asked, ['a.jpg', 'b.gif']);
      expect(results, [
        SaveResult.saved('${desk.root.path}/picked-a.jpg'),
        SaveResult.saved('${desk.root.path}/picked-b.gif'),
      ]);
      expect(mac.blocks, isEmpty);
    });

    test('a dismissed panel cancels the batch', () async {
      final desk = _Mac();
      final results = await desk.saver.save([
        photo(desk),
        photo(desk),
      ], const SaveDestination.ask()).results;

      expect(results, const [SaveResult.cancelled(), SaveResult.cancelled()]);
    });
  });

  test('bytes go to Downloads but not to Photos', () async {
    RecordingDiagnostics.install();
    final desk = _Mac();
    SaveItem bytes() => SaveItem.bytes(
      Uint8List.fromList([7, 7]),
      name: 'mem.jpg',
      mimeType: 'image/jpeg',
      kind: SaveItemKind.photo,
    );

    expect(
      await desk.saver.save([
        bytes(),
      ], const SaveDestination.downloads()).results,
      [SaveResult.saved(desk.downloads('mem.jpg'))],
    );
    expect(
      await desk.saver.save([bytes()], const SaveDestination.gallery()).results,
      [const SaveResult.failed(SaveFailure.unavailable, code: 'bytes')],
    );
  });

  test('macOS file error codes map to the failure they mean', () {
    const macos = DesktopPlatform.macos;
    expect(macos.failureOf(1), SaveFailure.accessDenied);
    expect(macos.failureOf(13), SaveFailure.accessDenied);
    expect(macos.failureOf(30), SaveFailure.accessDenied);
    expect(macos.failureOf(28), SaveFailure.noSpace);
    // EDQUOT is 69 on macOS, not Linux's 122.
    expect(macos.failureOf(69), SaveFailure.noSpace);
    expect(macos.failureOf(122), SaveFailure.unavailable);
    expect(macos.failureOf(2), SaveFailure.unavailable);
  });

  group('home folders', () {
    test('are fixed under the home', () async {
      const folders = MacosHomeFolders(environment: {'HOME': '/Users/u'});
      expect(
        await folders.pathOf(DesktopFolder.downloads),
        '/Users/u/Downloads',
      );
      expect(await folders.pathOf(DesktopFolder.pictures), '/Users/u/Pictures');
      expect(await folders.pathOf(DesktopFolder.videos), '/Users/u/Movies');
    });

    test('are none without a home', () async {
      const folders = MacosHomeFolders(environment: {});
      expect(await folders.pathOf(DesktopFolder.downloads), isNull);
    });
  });

  test(
    'the platform saver of a macOS app is this writer',
    () async {
      final diagnostics = RecordingDiagnostics.install();
      mac.status = 'denied';
      // Denied, so nothing is written into the user's own folders.
      await PlatformMediaSaver(methods: _methods).save([
        const SaveItem.file(
          '/nowhere/a',
          name: 'a.jpg',
          mimeType: 'image/jpeg',
          kind: SaveItemKind.photo,
        ),
      ], const SaveDestination.gallery()).results;

      expect(diagnostics.whereOp(SaveOp.jobStarted), [
        isMpxEvent(fields: containsPair('platform', 'macos')),
      ]);
    },
    skip: Platform.isMacOS ? false : 'needs a macOS host',
  );
}
