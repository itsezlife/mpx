import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_example/lab/corpus.dart';
import 'package:mpx_example/lab/lab_download.dart';

/// The real network stack, whatever the test binding mocks.
final class _Real extends HttpOverrides {}

void main() {
  late Directory dir;
  late Corpus corpus;
  late LoopbackOrigin origin;
  late IRangedBytesStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('lab_download');
    Directory('${dir.path}/corpus').createSync();
    File('${dir.path}/corpus/a.mp4').writeAsBytesSync(List.filled(300000, 1));
    File('${dir.path}/corpus/b.gif').writeAsBytesSync(List.filled(1000, 2));
    File('${dir.path}/corpus/manifest.json').writeAsStringSync(
      jsonEncode({
        'entries': [
          {'file': 'a.mp4', 'kind': 'video'},
          {'file': 'b.gif', 'kind': 'animated'},
        ],
      }),
    );
    corpus = (await Corpus.load('${dir.path}/corpus'))!;
    origin = await LoopbackOrigin.serve(corpus.directory);
    store =
        await BytesCache.open(
              directory: '${dir.path}/cache',
              throwOnOpenFailure: true,
            )
            as IRangedBytesStore;
  });

  tearDown(() async {
    await store.close();
    await origin.close();
    dir.deleteSync(recursive: true);
  });

  Future<List<String>> download(String value) async {
    final lines = <String>[];
    // The client's sockets come from the zone it is made in.
    await HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpBytesClient();
      final ranged = RangedBytes(store: store, client: client);
      try {
        await LabDownload.run(
          ranged: ranged,
          corpus: corpus,
          value: value,
          urlOf: origin.urlOf,
          log: lines.add,
        );
      } finally {
        await ranged.close();
        await client.close();
      }
    }, _Real());
    return lines;
  }

  test('a file downloads whole, one pass at a time then all at once', () async {
    final lines = await download('a.mp4');

    expect(lines.first, 'dl start files=1');
    expect(
      lines.where((l) => l.startsWith('dl a.mp4 bytes=300000 ')),
      hasLength(2),
    );
    expect(lines.where((l) => l.endsWith('kbps=0')), isEmpty);
    expect(
      lines.where((l) => l.startsWith('dl total ')).map((l) => l.split(' ')[2]),
      ['pass=serial', 'pass=parallel'],
    );
    expect(lines.last, 'dl done');
  });

  test('an unknown file is refused, and the run still ends', () async {
    expect(await download('none.mp4'), [
      'dl refused: no corpus entry for "none.mp4"',
      'dl done',
    ]);
  });
}
