import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_example/transfers/dev_server.dart';
import 'package:mpx_example/transfers/transfer_settings.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../../tool/upload_server/dev_upload_server.dart';

/// The platform's own HTTP client, past the fake one a widget test's
/// binding installs for the whole process.
final class _RealHttp extends HttpOverrides {}

Future<T> _real<T>(Future<T> Function() body) =>
    HttpOverrides.runWithHttpOverrides(body, _RealHttp());

void main() {
  late Directory folder;
  late DevUploadServer server;
  late DevServer host;
  late http.Client client;

  setUp(() async {
    folder = Directory.systemTemp.createTempSync('mpx_upload_server_');
    await _real(() async {
      server = await DevUploadServer.start(
        directory: Directory('${folder.path}/files'),
        port: 0,
        address: InternetAddress.loopbackIPv4,
      );
      client = http.Client();
    });
    host = DevServer(
      Uri.parse('http://127.0.0.1:${server.port}'),
      client: client,
    );
  });

  tearDown(() async {
    client.close();
    await server.close();
    folder.deleteSync(recursive: true);
  });

  File source(int size) {
    final file = File('${folder.path}/source-$size.bin')
      ..writeAsBytesSync(
        Uint8List.fromList(List.generate(size, (i) => i % 251)),
      );
    return file;
  }

  // Uploads a file of [size] bytes through [transport] over the real
  // engine and answers the item's snapshot once the job ended.
  Future<PublishJobSnapshot> upload(DemoTransport transport, int size) =>
      _real(() async {
        final bytes = HttpBytesClient(transfers: const HttpBytesTransfers());
        addTearDown(bytes.close);
        final harness = await UploadsHarness.open(
          lifecycle: ManualPlaybackLifecycleSource(),
          transports: host.transports(bytes),
          client: bytes,
        );
        addTearDown(harness.transfers.dispose);
        final file = source(size);
        final job = harness.transfers.upload(
          PublishItem(
            itemId: 'item',
            key: MediaKey.local(
              '00000000-0000-4000-8000-${'$size'.padLeft(12, '0')}',
            ),
            source: PublishSource.prepared(
              PreparedMedia(
                kind: PreparedKind.file,
                path: file.path,
                isOriginal: true,
                byteSize: size,
                mimeType: 'video/mp4',
              ),
            ),
          ),
          transport: transport.id,
        );
        return job.watch().firstWhere(
          (snapshot) =>
              snapshot.state is PublishJobState$Completed ||
              snapshot.state is PublishJobState$Failed,
        );
      });

  for (final transport in DemoTransport.values) {
    test('a file goes up through ${transport.label} and the server keeps it '
        'whole', () async {
      const size = 300 * 1024;
      final done = await upload(transport, size);

      expect(done.state, isA<PublishJobState$Completed>());
      final file = switch (done.items.single.state) {
        PublishItemState$Uploaded(:final file?) => file.id,
        final state => fail('not uploaded: $state'),
      };
      final kept = server.files[file]!;
      expect(kept.size, size);
      final listed = await _real(host.files);
      expect(listed.map((file) => file.id), contains(file));
      expect(
        File('${server.directory.path}/$file').readAsBytesSync(),
        source(size).readAsBytesSync(),
      );
    });
  }

  test('an upload while the server fails gives up retryable; once it takes '
      'parts again a retry completes', () async {
    server.control({'upload': 'fail'});
    final failed = await upload(DemoTransport.multipart, 1024);

    expect(failed.state, isA<PublishJobState$Failed>());
    expect((failed.state as PublishJobState$Failed).retryable, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('publish', () {
    Future<PublishOutcome> publish(String key, {Map<String, String>? files}) =>
        _real(
          () => DevServerPublisher(host, client: client).publish(Uint8List(0), {
            for (final MapEntry(key: item, value: file)
                in (files ?? {'a': 'f1.bin'}).entries)
              item: PublishItemRefs(
                key: MediaKey.local('00000000-0000-4000-8000-000000000001'),
                file: RemoteRef(file),
              ),
          }, key),
        );

    setUp(() async {
      // The server's first file: f1.bin.
      final bytes = Uint8List.fromList([1, 2, 3]);
      final response = await _real(
        () => client.send(
          http.MultipartRequest('POST', host.url('/multipart'))
            ..files.add(
              http.MultipartFile.fromBytes('file', bytes, filename: 'a'),
            ),
        ),
      );
      expect(response.statusCode, 200);
    });

    test('published answers each item\'s file as its server key', () async {
      final outcome = await publish('k1', files: {'a': 'f1.bin'});

      expect(
        outcome,
        PublishOutcome.published(serverKeys: {'a': DevServer.keyOf('f1.bin')}),
      );
      expect(server.publishes, {'k1': 1});
    });

    test('reject and rejectRetryable refuse the publish', () async {
      server.control({'publish': 'reject'});
      expect(
        await publish('k1'),
        const PublishOutcome.rejected(reason: 'server_rejected'),
      );
      server.control({'publish': 'rejectRetryable'});
      expect(
        await publish('k1'),
        const PublishOutcome.rejected(reason: 'server_busy', retryable: true),
      );
    });

    test('reupload asks once per key, then publishes', () async {
      server.control({'publish': 'reupload'});

      expect(await publish('k1'), PublishOutcome.reuploadItems(const ['a']));
      expect(await publish('k1'), isA<PublishOutcome$Published>());
      expect(server.publishes, {'k1': 2});
    });
  });

  test('the server serves a kept file by ranges and the resolver describes '
      'it', () async {
    final bytes = Uint8List.fromList(List.generate(100, (i) => i));
    File('${server.directory.path}/clip.mp4').writeAsBytesSync(bytes);
    await server.close();
    server = await _real(
      () => DevUploadServer.start(
        directory: server.directory,
        port: 0,
        address: InternetAddress.loopbackIPv4,
      ),
    );
    host = DevServer(
      Uri.parse('http://127.0.0.1:${server.port}'),
      client: client,
    );

    final ranged = await _real(
      () => client.get(
        host.locationOf(DevServer.keyOf('clip.mp4'))!,
        headers: {'range': 'bytes=10-19'},
      ),
    );
    expect(ranged.statusCode, 206);
    expect(ranged.bodyBytes, bytes.sublist(10, 20));
    expect(ranged.headers['content-range'], 'bytes 10-19/100');

    final described = await _real(
      () => DevServerResolver(host).resolve([
        DevServer.keyOf('clip.mp4'),
        const MediaKey.remote('elsewhere'),
      ]),
    );
    expect(described.keys, [DevServer.keyOf('clip.mp4')]);
    expect(described.values.single.kind, MediaKind.video);
    expect(described.values.single.byteSize, 100);
  });

  test('control switches the modes and answers them', () async {
    final modes = await _real(
      () => host.control(upload: 'fail', publish: 'reupload', rateKiBs: 64),
    );

    expect(modes, {'upload': 'fail', 'publish': 'reupload', 'rateKiBs': 64});
    expect(server.uploadMode, UploadMode.fail);
    expect(server.publishMode, PublishMode.reupload);
    expect(server.rateBytesPerSecond, 64 * 1024);
  });
}
