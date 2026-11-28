import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/src/platform/android_save_wire.dart';
import 'package:mpx_library/src/platform/android_save_writer.dart';
import 'package:mpx_library/src/platform/platform_save_access.dart';
import 'package:mpx_library/testing.dart';

const _methods = MethodChannel('test.mpx.library/android-save');

/// The plugin's native saver on Android as the Dart side sees it: every
/// write copies in [steps] steps of [stepBytes] bytes, and a test scripts
/// what goes wrong.
final class _NativeSaver {
  _NativeSaver(this.messenger) {
    messenger.setMockMethodCallHandler(_methods, _handle);
  }

  final TestDefaultBinaryMessenger messenger;

  int steps = 2;
  int stepBytes = 100;

  /// What `saveAccess` / `requestSaveAccess` answer.
  Map<String, Object?> access = {'scope': 'none', 'status': 'authorized'};

  /// The error code the next `saveBegin` fails with.
  String? failBegin;

  /// The error code the next `saveStep` fails with.
  String? failStep;

  /// The `saveBegin` of the system dialog answers null (dismissed).
  bool dismissAsk = false;

  /// The ref the next finished write is saved as, renamed.
  bool renameNext = false;

  final List<AndroidSaveStart> started = [];
  final List<String> calls = [];
  final Set<int> aborted = {};
  final Map<int, int> _done = {};
  int _lastWrite = 0;

  static const _start = AndroidSaveStartCodec();
  static const _step = AndroidSaveStepCodec();

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call.method);
    final args = call.arguments as Map<Object?, Object?>?;
    switch (call.method) {
      case 'saveAccess' || 'requestSaveAccess':
        return access;
      case 'saveBegin':
        final start = _start.decode(args!);
        started.add(start);
        if (failBegin case final code?) {
          failBegin = null;
          throw PlatformException(code: code, message: '/secret/path');
        }
        if (start.destination == 'ask' && dismissAsk) return null;
        _done[++_lastWrite] = 0;
        return _lastWrite;
      case 'saveStep':
        final write = args!['write']! as int;
        if (failStep case final code?) {
          failStep = null;
          _done.remove(write);
          throw PlatformException(code: code, message: '/secret/path');
        }
        final done = _done[write]! + 1;
        _done[write] = done;
        final total = steps * stepBytes;
        if (done < steps) {
          return _step.encode(AndroidSaveStep.copying(done * stepBytes, total));
        }
        final renamed = renameNext;
        renameNext = false;
        return _step.encode(
          AndroidSaveStep.done(
            total,
            ref: 'content://media/external/images/media/$write',
            renamed: renamed,
          ),
        );
      case 'saveAbort':
        aborted.add(args!['write']! as int);
        return null;
    }
    return null;
  }

  int get begun => calls.where((c) => c == 'saveBegin').length;
}

/// The platform saver as Android composes it, over the test channel.
MediaSaver _androidSaver({TrackedTransfers? transfers}) {
  const access = PlatformSaveAccess(_methods, platform: TargetPlatform.android);
  return PlatformMediaSaver.over(
    const AndroidSaveWriter(_methods, access: access),
    methods: _methods,
    transfers: transfers,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _NativeSaver native;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    native = _NativeSaver(messenger);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(_methods, null);
  });

  SaveItem photo(int index, {DateTime? createdAt}) => SaveItem.file(
    '/host/photo-$index.jpg',
    name: 'photo-$index.jpg',
    mimeType: 'image/jpeg',
    kind: SaveItemKind.photo,
    createdAt: createdAt,
  );

  MediaSaver saver() => _androidSaver();

  group('contract', () {
    for (final destination in const [
      SaveDestination.gallery(album: 'Album'),
      SaveDestination.downloads(subfolder: 'Host'),
    ]) {
      MediaSaverContract.run(() {
        final native = _NativeSaver(messenger);
        final transfers = FakeTrackedTransfers();
        return MediaSaverHarness(
          saver: _androidSaver(transfers: transfers),
          file: (index) => '/host/source-$index.jpg',
          destination: destination,
          // Android 28 and below: the legacy write permission, refused.
          denyAccess: () =>
              native.access = {'scope': 'legacyWrite', 'status': 'denied'},
          transfers: transfers,
          withoutTransfers: _androidSaver,
        );
      });
    }
  });

  test('begins each item with what the native side files it by', () async {
    final createdAt = DateTime.utc(2026, 5, 4, 3, 2, 1);
    final results = await saver().save([
      photo(0, createdAt: createdAt),
      const SaveItem.file(
        '/host/clip.mp4',
        name: 'clip.mp4',
        mimeType: 'video/mp4',
        kind: SaveItemKind.file,
        move: true,
      ),
    ], const SaveDestination.gallery(album: 'Album')).results;

    expect(results, everyElement(isA<SaveResult$Saved>()));
    expect(native.started, [
      AndroidSaveStart(
        destination: 'gallery',
        folder: 'Album',
        name: 'photo-0.jpg',
        mimeType: 'image/jpeg',
        kind: SaveItemKind.photo,
        createdAt: createdAt,
        path: '/host/photo-0.jpg',
      ),
      // A file sent to the gallery goes as what its MIME type says.
      const AndroidSaveStart(
        destination: 'gallery',
        folder: 'Album',
        name: 'clip.mp4',
        mimeType: 'video/mp4',
        kind: SaveItemKind.video,
        path: '/host/clip.mp4',
        move: true,
      ),
    ]);
  });

  test('sends the downloads sub-folder, and bytes without a file', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    await saver().save([
      SaveItem.bytes(
        bytes,
        name: 'notes.txt',
        mimeType: 'text/plain',
        kind: SaveItemKind.file,
      ),
    ], const SaveDestination.downloads(subfolder: 'Host')).results;

    final start = native.started.single;
    expect(start.destination, 'downloads');
    expect(start.folder, 'Host');
    expect(start.path, isNull);
    expect(start.bytes, bytes);
  });

  test('reports each step as progress and the saved content URI', () async {
    native
      ..steps = 4
      ..renameNext = true;
    final diagnostics = RecordingDiagnostics.install();
    final job = saver().save([photo(0)], const SaveDestination.gallery());
    final seen = <double>[];
    job.progress.addListener(() => seen.add(job.progress.value));

    final results = await job.results;

    expect(results, [
      const SaveResult.saved(
        'content://media/external/images/media/1',
        renamed: true,
      ),
    ]);
    expect(seen, [0.25, 0.5, 0.75, 1]);
    final saved = diagnostics.whereOp(SaveOp.itemSaved).single;
    expect(saved.fields['bytes'], 400);
    expect(saved.fields['renamed'], isTrue);
    expect(native.aborted, isEmpty);
  });

  test('a cancel mid-copy aborts the write, which drops its pending '
      'row', () async {
    native.steps = 5;
    final diagnostics = RecordingDiagnostics.install();
    final job = saver().save([
      photo(0),
      photo(1),
    ], const SaveDestination.gallery());
    job.progress.addListener(() {
      // One step of five into the first of two items.
      if (job.progress.value >= 0.1) job.cancel();
    });

    expect(await job.results, [
      const SaveResult.cancelled(),
      const SaveResult.cancelled(),
    ]);
    expect(native.aborted, {1});
    expect(
      diagnostics.whereOp(SaveOp.itemCancelled).map((e) => e.fields['index']),
      [0, 1],
    );
    expect(native.begun, 1, reason: 'the second item never began');
    expect(
      native.calls.where((c) => c == 'saveStep'),
      hasLength(1),
      reason: 'no step after the cancel',
    );
  });

  test('a dismissed save dialog cancels its item and the rest', () async {
    native.dismissAsk = true;
    final results = await saver().save([
      photo(0),
      photo(1),
    ], const SaveDestination.ask()).results;

    expect(results, [
      const SaveResult.cancelled(),
      const SaveResult.cancelled(),
    ]);
    expect(native.begun, 1);
  });

  group('a platform error fails the item for its reason', () {
    for (final (code, reason) in [
      ('ENOSPC', SaveFailure.noSpace),
      ('mimeRejected', SaveFailure.unsupportedFormat),
      ('security', SaveFailure.accessDenied),
      ('sourceMissing', SaveFailure.unavailable),
      ('insertFailed', SaveFailure.unavailable),
      ('nameTaken', SaveFailure.unavailable),
      ('noActivity', SaveFailure.unavailable),
      ('failed', SaveFailure.unavailable),
    ]) {
      test('$code at the start', () async {
        native.failBegin = code;
        final results = await saver().save([
          photo(0),
        ], const SaveDestination.gallery()).results;
        expect(results, [SaveResult.failed(reason, code: code)]);
      });
    }

    test('mid-copy, with the code and no path in the event', () async {
      native.failStep = 'ENOSPC';
      final diagnostics = RecordingDiagnostics.install();

      final results = await saver().save([
        photo(0),
        photo(1),
      ], const SaveDestination.downloads()).results;

      expect(results, [
        const SaveResult.failed(SaveFailure.noSpace, code: 'ENOSPC'),
        isA<SaveResult$Saved>(),
      ]);
      final failed = diagnostics.whereOp(SaveOp.itemFailed).single;
      expect(failed.fields, {
        'index': 0,
        'reason': 'noSpace',
        'code': 'ENOSPC',
      });
      expect('${failed.error}', isNot(contains('/secret')));
    });
  });

  test('a refused legacy write permission begins nothing', () async {
    native.access = {'scope': 'legacyWrite', 'status': 'denied'};
    final results = await saver().save([
      photo(0),
    ], const SaveDestination.gallery()).results;

    expect(results, [const SaveResult.failed(SaveFailure.accessDenied)]);
    expect(native.begun, 0);
  });

  group('wire', () {
    const start = AndroidSaveStartCodec();
    const step = AndroidSaveStepCodec();

    test('a start goes over the channel and back unchanged', () {
      final value = AndroidSaveStart(
        destination: 'downloads',
        folder: 'Host',
        name: 'a.bin',
        mimeType: 'application/octet-stream',
        kind: SaveItemKind.file,
        createdAt: DateTime.utc(2026),
        bytes: Uint8List.fromList([7]),
      );
      expect(start.decode(start.encode(value)), value);
      expect(start.encode(value), {
        'destination': 'downloads',
        'folder': 'Host',
        'name': 'a.bin',
        'mime': 'application/octet-stream',
        'kind': 'file',
        'createdAtMs': DateTime.utc(2026).millisecondsSinceEpoch,
        'bytes': [7],
        'move': false,
      });
    });

    test('a step decodes strictly, naming the field', () {
      expect(
        step.decode({'written': 1, 'total': 2}),
        const AndroidSaveStep.copying(1, 2),
      );
      expect(
        step.decode({
          'written': 2,
          'total': 2,
          'done': true,
          'ref': 'content://x',
          'renamed': false,
        }),
        const AndroidSaveStep.done(2, ref: 'content://x', renamed: false),
      );
      expect(
        () => step.decode({'total': 2}),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', 'written'),
        ),
      );
      expect(
        () => step.decode({'written': 2, 'done': true}),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', 'ref'),
        ),
      );
    });
  });
}
