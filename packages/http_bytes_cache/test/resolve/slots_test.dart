import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:test/test.dart';

import '../support/upload_server.dart';

/// One connection cap shared by both directions, with a share for each.
void main() {
  group('Connection slots', () {
    late UploadServer server;
    late Directory dir;
    late File file;
    late Completer<void> getsBlocked;
    late int getsActive;
    late int getsPeak;
    late HttpBytesClient client;

    Future<void> until(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 150));

    Future<HttpBytesResponse> upload() => client.upload(
      server.url(),
      body: HttpBytesUploadBody.file(file.path, length: 64 * 1024),
    );

    Future<void> get(int i) =>
        client.getBytes(Uri.parse('https://cdn.example.com/$i'));

    setUp(() async {
      server = (await UploadServer.start())
        ..keepUpTo = 0
        ..holdAfter = 1;
      dir = Directory.systemTemp.createTempSync('http_bytes_slots_');
      file = patternFile('${dir.path}/part', 64 * 1024);
      getsBlocked = Completer<void>();
      getsActive = 0;
      getsPeak = 0;
      client = HttpBytesClient(
        middlewares: const [],
        client: MockClient((request) async {
          getsActive++;
          if (getsActive > getsPeak) getsPeak = getsActive;
          await getsBlocked.future;
          getsActive--;
          return http.Response.bytes([1], 200);
        }),
      );
    });

    tearDown(() async {
      if (!server.release.isCompleted) server.release.complete();
      if (!getsBlocked.isCompleted) getsBlocked.complete();
      await client.close();
      await server.close();
      dir.deleteSync(recursive: true);
    });

    test('the defaults are 8 in all, 6 for each direction', () {
      final defaults = HttpBytesClient();
      addTearDown(defaults.close);

      expect(defaults.maxConcurrent, 8);
      expect(defaults.maxDownloads, 6);
      expect(defaults.maxUploads, 6);
    });

    test('with 8 uploads queued, GETs still run', () async {
      getsBlocked.complete();
      final uploads = [for (var i = 0; i < 8; i++) upload()];
      await until(() => server.received.length == 6);
      await settle();

      expect(server.received, hasLength(6));
      await get(0).timeout(const Duration(seconds: 5));

      server.release.complete();
      await Future.wait(uploads);
      expect(server.received, hasLength(8));
    });

    test('with 10 GETs queued, 6 run and uploads still get their 2', () async {
      final gets = [for (var i = 0; i < 10; i++) get(i)];
      await until(() => getsActive == 6);
      final uploads = [upload(), upload(), upload()];
      await until(() => server.received.length == 2);
      await settle();

      // 6 GETs and 2 uploads fill the 8.
      expect(getsActive, 6);
      expect(server.received, hasLength(2));

      getsBlocked.complete();
      server.release.complete();
      await Future.wait([...gets, ...uploads]);
      expect(getsPeak, 6);
      expect(server.received, hasLength(3));
    });

    test('a host that sends nothing runs 6 GETs at once', () async {
      final gets = [for (var i = 0; i < 9; i++) get(i)];
      await until(() => getsActive == 6);
      await settle();

      expect(getsActive, 6);
      getsBlocked.complete();
      await Future.wait(gets);
      expect(getsPeak, 6);
    });
  });
}
