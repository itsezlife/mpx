import 'dart:isolate';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';

/// An isolate group that serves the native reader and never closes it: it
/// attaches, publishes `args[1]` from a store in `args[0]`, reports `ready`,
/// and waits to be killed (as a hot restart drops the previous isolates).
Future<void> main(List<String> args, SendPort replies) async {
  final store =
      await BytesCache.open(directory: args[0], throwOnOpenFailure: true)
          as IRangedBytesStore;
  final readers = NativeRangedReaders(RangedBytes(store: store));
  await readers.publish(
    RangedRequest(
      url: Uri.parse('http://127.0.0.1:1/abandoned.mp4'),
      cacheKey: BytesCacheKey(args[1]),
    ),
  );
  replies.send('ready');
}
