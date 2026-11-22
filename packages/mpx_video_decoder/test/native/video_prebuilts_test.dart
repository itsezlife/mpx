import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// The hook is not part of lib/: a hook may not import the Flutter package
// ignore: avoid_relative_lib_imports, always_use_package_imports
import '../../hook/src/video_prebuilts.dart';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

Map<String, Object?> _file(String name, List<int> bytes, {String? file}) => {
  'name': name,
  'file': file ?? 'mpx_video-android-arm64-$name',
  'sha256': _sha(bytes),
  'size': bytes.length,
};

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('mpx_video_pre'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('VideoPrebuiltManifest', () {
    test('reads each target\'s files: the name it is bundled under, the '
        'release file, its hash and size', () {
      final manifest = VideoPrebuiltManifest.parse(
        jsonEncode({
          'schema': 1,
          'sourceHash': 'a' * 64,
          'baseUrl': 'https://example.com/releases/download/t/',
          'targets': {
            'android-arm64': [
              _file('libmpx_video.so', [1, 2, 3]),
              _file('libavcodec.so', [4]),
            ],
          },
        }),
      );

      final files = manifest.filesFor('android-arm64')!;
      expect(files.map((f) => f.name), ['libmpx_video.so', 'libavcodec.so']);
      expect(
        manifest.urlOf(files.first).toString(),
        'https://example.com/releases/download/t/'
        'mpx_video-android-arm64-libmpx_video.so',
      );
      expect(manifest.filesFor('macos-arm64'), isNull);
    });

    test('an empty manifest is valid: nothing is published yet', () {
      final manifest = VideoPrebuiltManifest.parse(
        jsonEncode({
          'schema': 1,
          'sourceHash': 'a' * 64,
          'baseUrl': '',
          'targets': <String, Object?>{},
        }),
      );

      expect(manifest.baseUrl, isNull);
      expect(manifest.filesFor('android-arm64'), isNull);
    });

    test('refuses what it cannot trust', () {
      Map<String, Object?> doc({
        Object? hash,
        String base = 'https://example.com/r/',
        String name = 'libavcodec.so',
      }) => {
        'schema': 1,
        'sourceHash': 'a' * 64,
        'baseUrl': base,
        'targets': {
          'android-arm64': [
            {
              'name': name,
              'file': 'f.so',
              'sha256': hash ?? 'b' * 64,
              'size': 1,
            },
          ],
        },
      };

      for (final bad in [
        doc(hash: 'xyz'),
        doc(base: 'http://example.com/r/'),
        doc(name: '../libavcodec.so'),
        {'schema': 2},
      ]) {
        expect(
          () => VideoPrebuiltManifest.parse(jsonEncode(bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  group('videoSourceHash', () {
    test('changes when a source the libraries are built from changes', () {
      final native = Directory('${temp.path}/native');
      for (final path in videoSourceFiles) {
        File('${native.path}/$path')
          ..createSync(recursive: true)
          ..writeAsStringSync('one $path');
      }

      final before = videoSourceHash(native);
      File('${native.path}/${videoSourceFiles.first}').writeAsStringSync('two');

      expect(before, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(videoSourceHash(native), isNot(before));
    });

    test('reads CRLF and LF checkouts alike', () {
      String hashOf(String eol) {
        final native = Directory('${temp.path}/$eol.hashCode/native');
        for (final path in videoSourceFiles) {
          File('${native.path}/$path')
            ..createSync(recursive: true)
            ..writeAsStringSync('a${eol}b$eol');
        }
        return videoSourceHash(native);
      }

      expect(hashOf('\r\n'), hashOf('\n'));
    });
  });

  group('planVideoDelivery', () {
    test('a dev override wins, then the prebuilt, then a local build', () {
      expect(
        planVideoDelivery(userPrefix: true, prebuilt: true, localPrefix: true),
        [
          VideoDelivery.userPrefix,
          VideoDelivery.prebuilt,
          VideoDelivery.localPrefix,
        ],
      );
      expect(
        planVideoDelivery(
          userPrefix: false,
          prebuilt: true,
          localPrefix: false,
        ),
        [VideoDelivery.prebuilt],
      );
      expect(
        planVideoDelivery(
          userPrefix: false,
          prebuilt: false,
          localPrefix: false,
        ),
        isEmpty,
      );
    });
  });

  group('fetchVideoPrebuilts', () {
    late HttpServer server;
    final served = <String, List<int>>{};
    var requests = 0;

    // A widget-test binding elsewhere in the process answers every request
    // with 400 through HttpOverrides: these talk to a real local server.
    HttpOverrides? previous;
    setUp(() => previous = HttpOverrides.current);
    tearDown(() => HttpOverrides.global = previous);

    setUp(() async {
      HttpOverrides.global = null;
      requests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        requests++;
        final body = served[request.uri.pathSegments.last];
        if (body == null) {
          request.response.statusCode = 404;
        } else {
          request.response.add(body);
        }
        request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    VideoPrebuiltManifest manifestOf(List<Map<String, Object?>> files) =>
        VideoPrebuiltManifest.parse(
          jsonEncode({
            'schema': 1,
            'sourceHash': 'a' * 64,
            'baseUrl': 'https://example.com/r/',
            'targets': {'android-arm64': files},
          }),
        );

    Uri local(VideoPrebuiltFile file) =>
        Uri.parse('http://127.0.0.1:${server.port}/${file.file}');

    test('downloads every file once, by the name it is bundled under, and '
        'serves later builds from the cache', () async {
      served['a.so'] = [1, 2, 3];
      served['b.so'] = [4, 5];
      final manifest = manifestOf([
        _file('libmpx_video.so', served['a.so']!, file: 'a.so'),
        _file('libavcodec.so', served['b.so']!, file: 'b.so'),
      ]);
      final cache = Directory('${temp.path}/cache');

      Future<VideoPrebuiltFetch> fetch() => fetchVideoPrebuilts(
        files: manifest.filesFor('android-arm64')!,
        urlOf: local,
        cacheDir: cache,
      );
      final first = await fetch();
      final second = await fetch();

      expect(first, isA<VideoPrebuiltsReady>());
      final ready = second as VideoPrebuiltsReady;
      expect(ready.files.keys, ['libmpx_video.so', 'libavcodec.so']);
      expect(ready.files['libavcodec.so']!.path, endsWith('/libavcodec.so'));
      expect(ready.files['libavcodec.so']!.readAsBytesSync(), [4, 5]);
      expect(requests, 2);
    });

    test('refuses a file whose bytes are not the manifest\'s, and keeps '
        'nothing of it', () async {
      served['a.so'] = [9, 9, 9];
      final manifest = manifestOf([
        _file('libmpx_video.so', [1, 2, 3], file: 'a.so'),
      ]);
      final cache = Directory('${temp.path}/cache');

      final result = await fetchVideoPrebuilts(
        files: manifest.filesFor('android-arm64')!,
        urlOf: local,
        cacheDir: cache,
      );

      expect(result, isA<VideoPrebuiltsUnavailable>());
      expect((result as VideoPrebuiltsUnavailable).reason, contains('SHA-256'));
      expect(
        cache.existsSync()
            ? cache.listSync(recursive: true).whereType<File>()
            : const <File>[],
        isEmpty,
      );
    });

    test('a missing file is unavailable, never a thrown build', () async {
      final manifest = manifestOf([
        _file('libmpx_video.so', [1], file: 'gone.so'),
      ]);

      final result = await fetchVideoPrebuilts(
        files: manifest.filesFor('android-arm64')!,
        urlOf: local,
        cacheDir: Directory('${temp.path}/cache'),
      );

      expect(result, isA<VideoPrebuiltsUnavailable>());
    });
  });
}
