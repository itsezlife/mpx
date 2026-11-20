import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/mpx_library.dart';

const _methods = MethodChannel('test.mpx.library/methods');
const _events = EventChannel('test.mpx.library/events');

Map<String, Object?> _android({
  int sdk = 34,
  bool images = false,
  bool video = false,
  bool selected = false,
  bool legacy = false,
  bool asked = false,
}) => {
  'platform': 'android',
  'sdk': sdk,
  'images': images,
  'video': video,
  'selected': selected,
  'legacy': legacy,
  'asked': asked,
};

Map<String, Object?> _asset(
  String id, {
  String kind = 'photo',
  bool cloud = false,
}) => {
  'id': id,
  'kind': kind,
  'subtypes': ['favourite', 'nonsense'],
  'width': 4032,
  'height': 3024,
  'durationMs': kind == 'video' ? 7500 : null,
  'createdMs': 1700000000000,
  'modifiedMs': 1700000001000,
  'mime': kind == 'video' ? 'video/mp4' : 'image/jpeg',
  'size': 2400000,
  'cloud': cloud,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Map<String, Object?> accessMap;
  late List<MethodCall> calls;
  StreamController<Object?>? native;

  setUp(() {
    accessMap = {'platform': 'apple', 'status': 'authorized'};
    calls = [];
    native = StreamController<Object?>.broadcast();
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'access' || 'requestAccess':
          return accessMap;
        case 'albums':
          return [
            {
              'id': 'all',
              'kind': 'allMedia',
              'title': '',
              'count': 3,
              'cover': _asset('a'),
            },
            {
              'id': 'bucket:7',
              'kind': 'camera',
              'title': 'Camera',
              'count': 1,
              'startsAtEnd': true,
            },
          ];
        case 'page':
          final args = call.arguments as Map<Object?, Object?>;
          final offset = args['offset']! as int;
          final all = [
            _asset('a'),
            _asset('b', kind: 'video', cloud: true),
            _asset('c'),
          ];
          return {
            'total': all.length,
            'assets': all.skip(offset).take(args['limit']! as int).toList(),
          };
        case 'thumbnail':
          final args = call.arguments as Map<Object?, Object?>;
          if (args['id'] == 'gone') {
            throw PlatformException(code: 'unavailable');
          }
          return Uint8List.fromList([1, 2, 3]);
        case 'playable':
          final args = call.arguments as Map<Object?, Object?>;
          if (args['id'] == 'gone') {
            throw PlatformException(code: 'unavailable');
          }
          return args['id'] == 'b'
              ? 'content://media/external/video/media/b'
              : null;
        case 'original':
          final args = call.arguments as Map<Object?, Object?>;
          if (args['id'] == 'offline')
            throw PlatformException(code: 'download');
          native!.add({
            'type': 'progress',
            'request': args['request'],
            'received': 5,
            'total': 10,
          });
          await Future<void>.delayed(Duration.zero);
          return {'path': '/tmp/${args['id']}.jpg', 'mime': 'image/jpeg'};
      }
      return null;
    });
    messenger.setMockStreamHandler(
      _events,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          native!.stream.listen(events.success);
        },
      ),
    );
  });

  tearDown(() {
    messenger
      ..setMockMethodCallHandler(_methods, null)
      ..setMockStreamHandler(_events, null);
    unawaited(native?.close());
  });

  PlatformMediaLibrary library({Duration? debounce}) => PlatformMediaLibrary(
    methods: _methods,
    events: _events,
    changeDebounce: debounce ?? Duration.zero,
    watchLifecycle: false,
  );

  group('access mapping', () {
    test('Android', () {
      LibraryAccess map(Map<String, Object?> m) => LibraryWire.accessOf(m);
      expect(map(_android()), LibraryAccess.notDetermined);
      expect(map(_android(asked: true)), LibraryAccess.denied);
      expect(map(_android(images: true, video: true)), LibraryAccess.full);
      expect(map(_android(selected: true)), LibraryAccess.partial);
      expect(
        map(_android(sdk: 33, selected: true, asked: true)),
        LibraryAccess.denied,
        reason: 'no user-selected access before API 34',
      );
      expect(
        map(_android(images: true, asked: true)),
        LibraryAccess.denied,
        reason: 'images without video is not the whole library',
      );
      expect(map(_android(sdk: 32, legacy: true)), LibraryAccess.full);
      expect(
        map(_android(sdk: 32, images: true, video: true)),
        LibraryAccess.notDetermined,
        reason: 'below 33 only the storage permission counts',
      );
    });

    test('Apple', () {
      LibraryAccess map(String status) =>
          LibraryWire.accessOf({'platform': 'apple', 'status': status});
      expect(map('notDetermined'), LibraryAccess.notDetermined);
      expect(map('denied'), LibraryAccess.denied);
      expect(map('restricted'), LibraryAccess.restricted);
      expect(map('limited'), LibraryAccess.limited);
      expect(map('authorized'), LibraryAccess.full);
      expect(
        map('unavailable'),
        LibraryAccess.restricted,
        reason: 'a build without the opt-in reports restricted',
      );
    });
  });

  test('reads access at creation and notifies on an access event', () async {
    final lib = library();
    addTearDown(lib.dispose);
    await pumpEventQueue();
    expect(lib.access.value, LibraryAccess.full);
    final seen = <LibraryAccess>[];
    lib.access.addListener(() => seen.add(lib.access.value));
    native!.add({'type': 'access', 'platform': 'apple', 'status': 'limited'});
    await pumpEventQueue();
    expect(seen, [LibraryAccess.limited]);
    expect(await lib.manageSelected(), isTrue);
    expect(calls.map((c) => c.method), contains('manageSelected'));
  });

  test(
    'manageSelected does not reach the platform under full access',
    () async {
      final lib = library();
      addTearDown(lib.dispose);
      await pumpEventQueue();
      expect(await lib.manageSelected(), isFalse);
      expect(calls.map((c) => c.method), isNot(contains('manageSelected')));
    },
  );

  test('albums and pages are assembled from the wire', () async {
    final lib = library();
    addTearDown(lib.dispose);
    await pumpEventQueue();
    final albums = await lib.albums();
    expect(albums.first.kind, LibraryAlbumKind.allMedia);
    expect(albums.first.cover?.id, const LibraryAssetId('a'));
    expect(albums.last.startsAtEnd, isTrue);

    final page = await lib.page(
      const LibraryAlbumId('all'),
      offset: 1,
      limit: 5,
    );
    expect(page.offset, 1);
    expect(page.total, 3);
    expect(page.assets.map((a) => a.id.value), ['b', 'c']);
    final video = page.assets.first;
    expect(video.kind, LibraryAssetKind.video);
    expect(video.duration, const Duration(milliseconds: 7500));
    expect(video.byteSize, 2400000);
    expect(video.subtypes, {LibraryAssetSubtype.favourite});
    expect(video.created, DateTime.utc(2023, 11, 14, 22, 13, 20));
    expect(lib.isCloudHeld(video.id), isTrue);
    expect(lib.isCloudHeld(const LibraryAssetId('c')), isFalse);
  });

  test('without read access nothing reaches the platform', () async {
    accessMap = {'platform': 'apple', 'status': 'denied'};
    final lib = library();
    addTearDown(lib.dispose);
    await pumpEventQueue();
    expect(await lib.albums(), isEmpty);
    expect(
      (await lib.page(const LibraryAlbumId('all'), offset: 0, limit: 3)).assets,
      isEmpty,
    );
    expect(calls.map((c) => c.method), isNot(contains('page')));
  });

  test('platform errors map to library errors', () async {
    final lib = library();
    addTearDown(lib.dispose);
    expect(await lib.thumbnail(const LibraryAssetId('a'), pixels: 96), [
      1,
      2,
      3,
    ]);
    await expectLater(
      lib.thumbnail(const LibraryAssetId('gone'), pixels: 96),
      throwsA(isA<LibraryAssetUnavailable>()),
    );
    await expectLater(
      lib.original(const LibraryAssetId('offline')),
      throwsA(isA<LibraryDownloadFailed>()),
    );
  });

  test('a video plays from the URI the platform gives; a gone asset has '
      'none', () async {
    final media = library();
    addTearDown(media.dispose);
    expect(
      await media.playable(const LibraryAssetId('b')),
      Uri.parse('content://media/external/video/media/b'),
    );
    expect(await media.playable(const LibraryAssetId('a')), isNull);
    expect(await media.playable(const LibraryAssetId('gone')), isNull);
  });

  test('an original reports its download and is released once', () async {
    final lib = library();
    addTearDown(lib.dispose);
    await pumpEventQueue();
    final reports = <(int, int?)>[];
    final lease = await lib.original(
      const LibraryAssetId('b'),
      onProgress: (received, total) => reports.add((received, total)),
    );
    expect(lease.path, '/tmp/b.jpg');
    expect(reports, [(5, 10)]);
    await lease.release();
    await lease.release();
    expect(calls.where((c) => c.method == 'releaseOriginal'), hasLength(1));
  });

  test('Apple change details come out per album', () async {
    final lib = library();
    addTearDown(lib.dispose);
    final events = <LibraryChange>[];
    lib.changes.listen(events.add);
    native!
      ..add({
        'type': 'changed',
        'album': 'recents',
        'inserted': ['x'],
        'removed': ['y'],
        'changed': <String>[],
      })
      ..add({'type': 'changed'});
    await pumpEventQueue();
    expect(events, [
      const LibraryChange.album(
        LibraryAlbumId('recents'),
        inserted: {LibraryAssetId('x')},
        removed: {LibraryAssetId('y')},
      ),
      const LibraryChange.reload(),
    ]);
  });

  test('Android changes are debounced into one reload', () async {
    // Real time, shortened: the event channel's mock delivers on the real
    // event loop.
    final lib = library(debounce: const Duration(milliseconds: 120));
    addTearDown(lib.dispose);
    final events = <LibraryChange>[];
    lib.changes.listen(events.add);
    await pumpEventQueue();
    for (var i = 0; i < 5; i++) {
      native!.add({'type': 'changed'});
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    expect(events, isEmpty, reason: 'still inside the burst');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(events, [const LibraryChange.reload()]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(events, hasLength(1));
  });
}
