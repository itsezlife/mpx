import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/src/platform/save_block_codec.dart';
import 'package:mpx_library/testing.dart';

const _methods = MethodChannel('test.mpx.library/apple-save');

/// The native side of the save on iOS, over the plugin's method channel:
/// the save access, and one `saveBlock` per batch answered from [answer].
final class _FakeApple {
  /// The access status the gallery reads (`saveAccess`).
  String status = 'authorized';

  /// What a `requestSaveAccess` leaves.
  String afterRequest = 'authorized';

  /// Holds the access request open until completed, when set.
  Completer<void>? holdRequest;

  /// Holds the block open until completed, when set.
  Completer<void>? holdBlock;

  /// The block's answer; null saves every entry with a ref of its own.
  SaveBlockAnswer? answer;

  final List<SaveBlockRequest> blocks = [];

  static const _requests = SaveBlockRequestCodec();
  static const _answers = SaveBlockAnswerCodec();

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'saveAccess':
        return _access(call, status);
      case 'requestSaveAccess':
        await holdRequest?.future;
        status = afterRequest;
        return _access(call, status);
      case 'saveBlock':
        final request = _requests.decode(
          (call.arguments as Map<Object?, Object?>).cast(),
        );
        blocks.add(request);
        await holdBlock?.future;
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

  static Map<String, Object?> _access(MethodCall call, String status) {
    final arguments = call.arguments as Map<Object?, Object?>;
    final gallery = arguments['destination'] == 'gallery';
    return {
      'scope': gallery
          ? (arguments['album'] == true ? 'readWrite' : 'addOnly')
          : 'none',
      'status': gallery ? status : 'authorized',
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _FakeApple apple;

  setUp(() {
    apple = _FakeApple();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(_methods, apple.handle);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_methods, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final destination in const [
    SaveDestination.gallery(),
    SaveDestination.downloads(subfolder: 'Saved'),
    SaveDestination.ask(),
  ]) {
    group('to ${destination.name}', () {
      MediaSaverContract.run(() {
        final transfers = FakeTrackedTransfers();
        return MediaSaverHarness(
          saver: PlatformMediaSaver(methods: _methods, transfers: transfers),
          transfers: transfers,
          withoutTransfers: () => PlatformMediaSaver(methods: _methods),
          file: (index) => '/cache/source-$index',
          destination: destination,
          changeBlock: true,
          denyAccess: destination is SaveDestination$Gallery
              ? () => apple.status = 'denied'
              : null,
          failBlock: () => apple.answer = const SaveBlockAnswer$Failed(
            domain: 'photos',
            code: '3305',
          ),
        );
      });
    });
  }

  SaveItem item(
    int index, {
    SaveItemKind kind = SaveItemKind.photo,
    String mimeType = 'image/jpeg',
    DateTime? createdAt,
    bool move = false,
  }) => SaveItem.file(
    '/host/item-$index',
    name: 'item-$index',
    mimeType: mimeType,
    kind: kind,
    createdAt: createdAt,
    move: move,
  );

  test('a batch is one native block, its entries in order', () async {
    final createdAt = DateTime.utc(2026, 11, 28, 12);
    var released = 0;
    final results = await PlatformMediaSaver(methods: _methods).save([
      item(0, createdAt: createdAt, move: true),
      SaveItem.leased(
        ContentFileLease(path: '/cache/1', onRelease: () async => released++),
        name: 'loop.gif',
        mimeType: 'image/gif',
        kind: SaveItemKind.animation,
        move: true,
      ),
      item(2, kind: SaveItemKind.file, mimeType: 'video/mp4'),
    ], const SaveDestination.gallery(album: 'Trips')).results;

    expect(results, const [
      SaveResult.saved('ref-1-0'),
      SaveResult.saved('ref-1-1'),
      SaveResult.saved('ref-1-2'),
    ]);
    expect(released, 1);
    final block = apple.blocks.single;
    expect(block.destination, const SaveDestination.gallery(album: 'Trips'));
    expect(block.entries.map((e) => e.path), [
      '/host/item-0',
      '/cache/1',
      '/host/item-2',
    ]);
    expect(block.entries.map((e) => e.kind), [
      SaveItemKind.photo,
      SaveItemKind.animation,
      // A file sent to the gallery goes by its MIME type.
      SaveItemKind.video,
    ]);
    expect(block.entries.map((e) => e.move), [true, false, false]);
    expect(block.entries.first.createdAt, createdAt);
    expect(block.entries.first.name, 'item-0');
    expect(block.entries[1].mimeType, 'image/gif');
  });

  test('a non-media file to the gallery never reaches the block', () async {
    final results = await PlatformMediaSaver(methods: _methods).save([
      item(0),
      item(1, kind: SaveItemKind.file, mimeType: 'application/pdf'),
    ], const SaveDestination.gallery()).results;

    expect(results, const [
      SaveResult.saved('ref-1-0'),
      SaveResult.failed(SaveFailure.unsupportedFormat),
    ]);
    expect(apple.blocks.single.entries, hasLength(1));
  });

  test('renamed entries are reported renamed', () async {
    apple.answer = const SaveBlockAnswer$Saved([
      SaveBlockSaved('/docs/a'),
      SaveBlockSaved('/docs/a (1)', renamed: true),
    ]);
    final results = await PlatformMediaSaver(
      methods: _methods,
    ).save([item(0), item(1)], const SaveDestination.downloads()).results;

    expect(results, const [
      SaveResult.saved('/docs/a'),
      SaveResult.saved('/docs/a (1)', renamed: true),
    ]);
  });

  group('a failed block fails every item for the platform error', () {
    const cases = {
      ('photos', '3311'): SaveFailure.accessDenied,
      ('photos', '3310'): SaveFailure.accessDenied,
      ('photos', '3305'): SaveFailure.noSpace,
      ('photos', '3302'): SaveFailure.unsupportedFormat,
      ('photos', '3300'): SaveFailure.unavailable,
      ('cocoa', '640'): SaveFailure.noSpace,
      ('cocoa', '513'): SaveFailure.accessDenied,
      ('cocoa', '260'): SaveFailure.unavailable,
      ('posix', '28'): SaveFailure.noSpace,
      ('posix', '13'): SaveFailure.accessDenied,
      ('mpx', 'missingSource'): SaveFailure.unavailable,
    };
    for (final MapEntry(key: (domain, code), value: reason) in cases.entries) {
      test('$domain $code is ${reason.name}', () async {
        final diagnostics = RecordingDiagnostics.install();
        apple.answer = SaveBlockAnswer$Failed(domain: domain, code: code);
        final results = await PlatformMediaSaver(
          methods: _methods,
        ).save([item(0), item(1)], const SaveDestination.gallery()).results;

        final failed = SaveResult.failed(reason, code: '$domain.$code');
        expect(results, [failed, failed]);
        expect(
          diagnostics.whereOp(SaveOp.itemFailed).map((e) => e.fields['code']),
          ['$domain.$code', '$domain.$code'],
        );
      });
    }
  });

  test('a dismissed export picker cancels every item', () async {
    apple.answer = const SaveBlockAnswer$Cancelled();
    final results = await PlatformMediaSaver(
      methods: _methods,
    ).save([item(0), item(1)], const SaveDestination.ask()).results;

    expect(results, const [SaveResult.cancelled(), SaveResult.cancelled()]);
  });

  group('downloads without file sharing', () {
    test('fall back to the export picker and report it', () async {
      final diagnostics = RecordingDiagnostics.install();
      apple.answer = const SaveBlockAnswer$Saved([
        SaveBlockSaved('/picked/a'),
      ], fallback: SaveBlockFallback.noFileSharing);
      final job = PlatformMediaSaver(
        methods: _methods,
      ).save([item(0)], const SaveDestination.downloads());

      expect(await job.results, const [SaveResult.saved('/picked/a')]);
      expect(diagnostics.whereOp(SaveOp.fallbackToAsk), [
        isMpxEvent(jobId: job.id, fields: equals({'why': 'noFileSharing'})),
      ]);
    });

    test('with file sharing, save into Documents with no fallback', () async {
      final diagnostics = RecordingDiagnostics.install();
      final results = await PlatformMediaSaver(
        methods: _methods,
      ).save([item(0)], const SaveDestination.downloads()).results;

      expect(results, const [SaveResult.saved('ref-1-0')]);
      expect(diagnostics.whereOp(SaveOp.fallbackToAsk), isEmpty);
    });
  });

  test('a named album skipped under limited access is reported', () async {
    final diagnostics = RecordingDiagnostics.install();
    apple.answer = const SaveBlockAnswer$Saved([
      SaveBlockSaved('ref'),
    ], album: SaveBlockAlbum.skipped);
    final job = PlatformMediaSaver(
      methods: _methods,
    ).save([item(0)], const SaveDestination.gallery(album: 'Trips'));

    expect(await job.results, const [SaveResult.saved('ref')]);
    expect(diagnostics.whereOp(SaveOp.albumSkipped), [
      isMpxEvent(jobId: job.id, fields: equals({'why': 'limited'})),
    ]);
  });

  group('changeBlock', () {
    test('reports the block and its result', () async {
      final diagnostics = RecordingDiagnostics.install();
      final job = PlatformMediaSaver(
        methods: _methods,
      ).save([item(0), item(1)], const SaveDestination.gallery());
      await job.results;

      expect(diagnostics.whereOp(SaveOp.changeBlock), [
        isMpxEvent(
          jobId: job.id,
          fields: equals({'items': 2, 'result': 'saved'}),
        ),
      ]);
    });

    test('a cancel before the block, while access is asked, cancels '
        'every item and writes nothing', () async {
      final diagnostics = RecordingDiagnostics.install();
      apple
        ..status = 'notDetermined'
        ..holdRequest = Completer();
      final job = PlatformMediaSaver(
        methods: _methods,
      ).save([item(0), item(1)], const SaveDestination.gallery());
      await pumpEventQueue();
      job.cancel();
      apple.holdRequest!.complete();

      expect(await job.results, const [
        SaveResult.cancelled(),
        SaveResult.cancelled(),
      ]);
      expect(apple.blocks, isEmpty);
      expect(diagnostics.whereOp(SaveOp.changeBlock), [
        isMpxEvent(
          fields: equals({
            'items': 2,
            'result': 'cancelled',
            'cancel': 'before',
          }),
        ),
      ]);
    });

    test('a cancel during the block has no effect', () async {
      final diagnostics = RecordingDiagnostics.install();
      apple.holdBlock = Completer();
      final job = PlatformMediaSaver(
        methods: _methods,
      ).save([item(0), item(1)], const SaveDestination.gallery());
      await pumpEventQueue();
      expect(apple.blocks, hasLength(1));
      job.cancel();
      apple.holdBlock!.complete();

      expect(await job.results, everyElement(isA<SaveResult$Saved>()));
      expect(diagnostics.whereOp(SaveOp.changeBlock), [
        isMpxEvent(
          fields: equals({'items': 2, 'result': 'saved', 'cancel': 'during'}),
        ),
      ]);
    });
  });

  test('without the save define the gallery writes nothing', () async {
    apple.status = 'unavailable';
    final results = await PlatformMediaSaver(
      methods: _methods,
    ).save([item(0)], const SaveDestination.gallery()).results;

    expect(results, const [
      SaveResult.failed(SaveFailure.unavailable, code: 'defineMissing'),
    ]);
    expect(apple.blocks, isEmpty);
  });

  test('the wire round-trips and names a bad field', () {
    const requests = SaveBlockRequestCodec();
    const answers = SaveBlockAnswerCodec();
    final request = SaveBlockRequest(
      destination: const SaveDestination.downloads(subfolder: 'Saved'),
      entries: [
        SaveBlockEntry(
          path: '/a',
          name: 'a.mp4',
          mimeType: 'video/mp4',
          kind: SaveItemKind.video,
          createdAt: DateTime.utc(2026),
          move: true,
        ),
      ],
    );
    expect(requests.decode(requests.encode(request)), request);
    const answer = SaveBlockAnswer$Saved([
      SaveBlockSaved('x', renamed: true),
    ], fallback: SaveBlockFallback.noFileSharing);
    expect(answers.decode(answers.encode(answer)), answer);
    expect(
      () => answers.decode({'outcome': 'saved'}),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', 'items'),
      ),
    );
    expect(
      () => answers.decode({'outcome': 'lost'}),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', 'outcome'),
      ),
    );
    // The map holds refs and paths: a format error names the field only.
    expect(
      () => answers.decode({
        'outcome': 'saved',
        'items': [
          {'ref': '/secret/a.jpg', 'renamed': 'yes'},
        ],
      }),
      throwsA(isA<FormatException>().having((e) => e.source, 'source', isNull)),
    );
    expect(
      () => requests.decode({
        'destination': 'downloads',
        'entries': [
          {'path': '/secret/a.jpg', 'name': 'a.jpg', 'kind': 'sideways'},
        ],
      }),
      throwsA(isA<FormatException>().having((e) => e.source, 'source', isNull)),
    );
  });
}
