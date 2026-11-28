import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';

const _methods = MethodChannel('test.mpx.library/save');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  // What the native side answers to `saveAccess` and `requestSaveAccess`.
  late Map<String, Object?> current;
  late Map<String, Object?> afterRequest;

  void on(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  setUp(() {
    calls = [];
    current = {'scope': 'addOnly', 'status': 'notDetermined'};
    afterRequest = {'scope': 'addOnly', 'status': 'authorized'};
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'saveAccess' => current,
        'requestSaveAccess' => current = afterRequest,
        _ => null,
      };
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_methods, null));

  SaveItem photo(int index) => SaveItem.file(
    '/host/photo-$index.jpg',
    name: 'photo-$index.jpg',
    mimeType: 'image/jpeg',
    kind: SaveItemKind.photo,
  );

  group('Apple', () {
    setUp(() => on(TargetPlatform.iOS));

    test('reads the add-only access of the gallery without asking', () async {
      final saver = PlatformMediaSaver(methods: _methods);

      final states = <String, SaveAccess>{};
      for (final status in [
        'notDetermined',
        'denied',
        'restricted',
        'limited',
        'authorized',
        'unavailable',
      ]) {
        current = {'scope': 'addOnly', 'status': status};
        states[status] = await saver.access(const SaveDestination.gallery());
      }

      expect(states, {
        'notDetermined': SaveAccess.notDetermined,
        'denied': SaveAccess.denied,
        'restricted': SaveAccess.restricted,
        'limited': SaveAccess.limited,
        'authorized': SaveAccess.granted,
        'unavailable': SaveAccess.unavailable,
      });
      expect(calls.map((c) => c.method), everyElement('saveAccess'));
      expect(calls.first.arguments, {'destination': 'gallery', 'album': false});
    });

    test('asks once when not determined and reports the request', () async {
      final diagnostics = RecordingDiagnostics.install();
      final saver = PlatformMediaSaver(methods: _methods);

      expect(
        await saver.requestAccess(const SaveDestination.gallery()),
        SaveAccess.granted,
      );
      expect(
        await saver.requestAccess(const SaveDestination.gallery()),
        SaveAccess.granted,
      );

      expect(calls.where((c) => c.method == 'requestSaveAccess'), hasLength(1));
      expect(diagnostics.whereOp(SaveOp.accessRequested), [
        isMpxEvent(
          level: MpxEventLevel.info,
          fields: {'access': 'addOnly', 'result': 'granted'},
        ),
      ]);
    });

    test('a named album asks for read and write access', () async {
      current = {'scope': 'readWrite', 'status': 'notDetermined'};
      afterRequest = {'scope': 'readWrite', 'status': 'denied'};
      final saver = PlatformMediaSaver(methods: _methods);

      expect(
        await saver.requestAccess(
          const SaveDestination.gallery(album: 'Trips'),
        ),
        SaveAccess.denied,
      );
      expect(calls.last.arguments, {'destination': 'gallery', 'album': true});
    });

    test('denied access fails every item accessDenied after one ask', () async {
      final diagnostics = RecordingDiagnostics.install();
      afterRequest = {'scope': 'addOnly', 'status': 'denied'};
      final job = PlatformMediaSaver(
        methods: _methods,
      ).save([photo(0), photo(1)], const SaveDestination.gallery());

      expect(await job.results, [
        const SaveResult.failed(SaveFailure.accessDenied),
        const SaveResult.failed(SaveFailure.accessDenied),
      ]);
      expect(calls.where((c) => c.method == 'requestSaveAccess'), hasLength(1));
      expect(diagnostics.whereOp(SaveOp.accessRequested), [
        isMpxEvent(
          jobId: job.id,
          fields: {'access': 'addOnly', 'result': 'denied'},
        ),
      ]);
    });

    test('without the save define the gallery is unavailable', () async {
      final diagnostics = RecordingDiagnostics.install();
      current = {
        'scope': 'addOnly',
        'status': 'unavailable',
        'missing': 'MPX_LIBRARY_SAVE',
      };
      final job = PlatformMediaSaver(
        methods: _methods,
      ).save([photo(0), photo(1)], const SaveDestination.gallery());

      const unavailable = SaveResult.failed(
        SaveFailure.unavailable,
        code: 'defineMissing',
      );
      expect(await job.results, [unavailable, unavailable]);
      expect(calls.where((c) => c.method == 'requestSaveAccess'), isEmpty);
      expect(diagnostics.whereOp(SaveOp.defineMissing), [
        isMpxEvent(
          level: MpxEventLevel.warning,
          jobId: job.id,
          fields: {
            'destination': 'gallery',
            'named': false,
            'define': 'MPX_LIBRARY_SAVE',
          },
        ),
      ]);
    });
  });

  group('Android', () {
    setUp(() => on(TargetPlatform.android));

    test('29 and later need nothing: granted, no request', () async {
      current = {'scope': 'none', 'status': 'authorized'};
      final saver = PlatformMediaSaver(methods: _methods);

      expect(
        await saver.requestAccess(const SaveDestination.downloads()),
        SaveAccess.granted,
      );
      expect(calls.map((c) => c.method), ['saveAccess']);
    });

    test('28 and earlier ask for the legacy write permission', () async {
      final diagnostics = RecordingDiagnostics.install();
      current = {'scope': 'legacyWrite', 'status': 'notDetermined'};
      afterRequest = {'scope': 'legacyWrite', 'status': 'authorized'};
      final job = PlatformMediaSaver(
        methods: _methods,
      ).save([photo(0)], const SaveDestination.downloads(subfolder: 'App'));
      await job.results;

      expect(calls.map((c) => c.method), ['saveAccess', 'requestSaveAccess']);
      expect(calls.last.arguments, {
        'destination': 'downloads',
        'album': false,
      });
      expect(diagnostics.whereOp(SaveOp.accessRequested), [
        isMpxEvent(
          jobId: job.id,
          fields: {'access': 'legacyWrite', 'result': 'granted'},
        ),
      ]);
    });

    test('a permission the host did not declare is restricted', () async {
      current = {'scope': 'legacyWrite', 'status': 'restricted'};
      final job = PlatformMediaSaver(
        methods: _methods,
      ).save([photo(0)], const SaveDestination.gallery());

      expect(await job.results, [
        const SaveResult.failed(SaveFailure.accessDenied),
      ]);
      expect(calls.map((c) => c.method), ['saveAccess']);
    });
  });

  test('desktops ask for nothing and call no native code', () async {
    on(TargetPlatform.linux);
    final saver = PlatformMediaSaver(methods: _methods);

    expect(
      await saver.requestAccess(const SaveDestination.gallery()),
      SaveAccess.granted,
    );
    expect(calls, isEmpty);
  });

  test('a native answer it cannot read is a format error naming the '
      'field', () async {
    on(TargetPlatform.iOS);
    current = {'scope': 'addOnly', 'status': 'sideways'};

    await expectLater(
      PlatformMediaSaver(
        methods: _methods,
      ).access(const SaveDestination.gallery()),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', 'status'),
      ),
    );
  });
}
