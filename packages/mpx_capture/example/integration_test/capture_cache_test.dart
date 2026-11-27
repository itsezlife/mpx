import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_core/mpx_core.dart';

/// A real compression lands in a disk store under a local media key, the
/// server key is aliased to it after a (pretend) upload, and the local key
/// is released on confirm.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'compressed output plays from the store, then under the server key',
    () async {
      final temp = Directory.systemTemp.createTempSync('mpx_capture_cache_it_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final source = '${temp.path}/source.mp4';
      final bytes = await rootBundle.load('assets/source.mp4');
      File(source).writeAsBytesSync(bytes.buffer.asUint8List());
      final storeDir = Directory('${temp.path}/store')..createSync();
      final store = await BytesCache.open(
        directory: storeDir.path,
        throwOnOpenFailure: true,
      );
      addTearDown(store.close);
      final cache = CaptureCache(store: store);

      final key = cache.mintKey();
      final output = await const PlatformTranscoder()
          .compress(
            TranscodeRequest(
              sourcePath: source,
              outputPath: '${temp.path}/send.mp4',
              preset: CompressionPreset.low,
            ),
          )
          .output;
      final compressed = File(output.path).readAsBytesSync();
      await cache.put(key, output);

      final local = CaptureCache.cacheKeyOf(key);
      expect(store.contains(local), isTrue);
      final lease = await store.leaseFile(local);
      expect(lease, isNotNull);
      final probed = await const PlatformTranscoder().probe(lease!.path);
      expect(probed.dimensions, output.dimensions, reason: 'a playable file');
      await lease.release();

      const server = BytesCacheKey('remote-42');
      expect(await cache.alias(key, server), isTrue);
      await cache.release(key);
      expect(store.contains(local), isFalse);
      expect(await store.read(server), compressed);
    },
  );
}
