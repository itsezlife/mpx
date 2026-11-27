// Uploads through `fetch` in a browser: a Blob slice and an OPFS file slice.
//
// Run with:
// dart test -p chrome test/upload/upload_web_test.dart
@TestOn('chrome')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  group('HttpBytesClient.upload on the web', () {
    final bytes = Uint8List.fromList([for (var i = 0; i < 10000; i++) i % 251]);
    late Uri url;
    late HttpBytesClient client;

    setUpAll(() async {
      final channel = spawnHybridUri('echo_server_hybrid.dart');
      final port = await channel.stream.first as int;
      url = Uri.parse('http://127.0.0.1:$port/upload');
    });

    setUp(() => client = HttpBytesClient());
    tearDown(() => client.close());

    test('sends a Blob slice through fetch', () async {
      final blob = web.Blob([bytes.toJS].toJS);
      final progress = <(int, int?)>[];

      final response = await client.upload(
        url,
        method: 'PUT',
        body: HttpBytesUploadBody.blob(blob, offset: 1000, length: 5000),
        onBytesSent: (sent, total) => progress.add((sent, total)),
      );

      expect(response.statusCode, 200);
      expect(response.headers['x-method'], 'PUT');
      expect(response.body, bytes.sublist(1000, 6000));
      expect(progress, [(0, 5000), (5000, 5000)]);
    });

    test('sends a prefix and a suffix around the slice', () async {
      final blob = web.Blob([bytes.toJS].toJS);
      final response = await client.upload(
        url,
        body: HttpBytesUploadBody.blob(
          blob,
          offset: 10,
          length: 20,
          prefix: const [1, 2],
          suffix: const [3],
        ),
      );
      expect(response.body, [1, 2, ...bytes.sublist(10, 30), 3]);
    });

    test('sends a slice of an OPFS file', () async {
      final root = await web.window.navigator.storage.getDirectory().toDart;
      final directory = await root
          .getDirectoryHandle(
            'http_bytes_upload_test',
            web.FileSystemGetDirectoryOptions(create: true),
          )
          .toDart;
      addTearDown(
        () => root
            .removeEntry(
              'http_bytes_upload_test',
              web.FileSystemRemoveOptions(recursive: true),
            )
            .toDart,
      );
      final handle = await directory
          .getFileHandle('source', web.FileSystemGetFileOptions(create: true))
          .toDart;
      final writable = await handle.createWritable().toDart;
      await writable.write(bytes.toJS).toDart;
      await writable.close().toDart;

      final response = await client.upload(
        url,
        body: const HttpBytesUploadBody.file(
          'http_bytes_upload_test/source',
          offset: 9000,
          length: 1000,
        ),
      );

      expect(response.body, bytes.sublist(9000));
    });

    test('a range past the end of its source fails before sending', () async {
      final blob = web.Blob([bytes.toJS].toJS);

      await expectLater(
        client.upload(
          url,
          body: HttpBytesUploadBody.blob(blob, offset: 9000, length: 1001),
        ),
        throwsA(isA<HttpBytesException$Internal>()),
      );
    });
  });
}
