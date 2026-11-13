import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/lab/corpus.dart';
import 'package:mpx_example/lab/stress_feed.dart';

/// The real network stack, whatever the test binding mocks.
final class _Real extends HttpOverrides {}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lab_corpus');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  void manifest(List<Map<String, Object?>> entries) => File(
    '${dir.path}/manifest.json',
  ).writeAsStringSync(jsonEncode({'entries': entries}));

  test('a corpus lists the manifest entries whose files exist', () async {
    File('${dir.path}/a.mp4').writeAsBytesSync(List.filled(10, 1));
    manifest([
      {
        'file': 'a.mp4',
        'kind': 'video',
        'codec': 'hevc',
        'width': 3840,
        'height': 2160,
        'fps': 60,
        'bitrate': 40000000,
        'duration': 20.0,
        'size': 10,
      },
      {'file': 'gone.webm', 'kind': 'loop'},
    ]);
    final corpus = (await Corpus.load(dir.path))!;
    expect(corpus.entries.map((e) => e.file), ['a.mp4']);
    expect(
      corpus.entries.single.describe(),
      'a.mp4 video hevc 3840x2160 60.00fps 40000kbps 20.0s 10B local',
    );
  });

  test('no manifest is no corpus', () async {
    expect(await Corpus.load(dir.path), isNull);
  });

  test('the fingerprint follows the files', () {
    const a = CorpusEntry(file: 'a.mp4', kind: CorpusKind.video, size: 1);
    const b = CorpusEntry(file: 'b.mp4', kind: CorpusKind.loop, size: 2);
    expect(
      const Corpus('x', [a, b]).fingerprint,
      const Corpus('y', [a, b]).fingerprint,
    );
    expect(
      const Corpus('x', [a, b]).fingerprint,
      isNot(const Corpus('x', [a]).fingerprint),
    );
  });

  test('the loopback origin answers whole files and ranges', () async {
    final bytes = List.generate(1000, (i) => i % 256);
    File('${dir.path}/clip.mp4').writeAsBytesSync(bytes);
    final origin = await LoopbackOrigin.serve(dir.path);
    addTearDown(origin.close);
    await HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpClient();
      addTearDown(client.close);
      Future<(int, List<int>, String?)> get(
        String file, [
        String? range,
      ]) async {
        final request = await client.getUrl(origin.urlOf(file));
        if (range != null) request.headers.set('range', range);
        final response = await request.close();
        final body = await response.expand((c) => c).toList();
        return (
          response.statusCode,
          body,
          response.headers.value('content-range'),
        );
      }

      final (status, body, _) = await get('clip.mp4');
      expect(status, 200);
      expect(body, bytes);
      final (partial, slice, range) = await get('clip.mp4', 'bytes=100-199');
      expect(partial, 206);
      expect(slice, bytes.sublist(100, 200));
      expect(range, 'bytes 100-199/1000');
      final (missing, _, _) = await get('none.mp4');
      expect(missing, 404);
    }, _Real());
    expect(origin.requests, 3);
    expect(origin.bytesSent, 1100);
  });

  test('the loopback origin holds to its bandwidth', () async {
    File('${dir.path}/big.bin').writeAsBytesSync(List.filled(200000, 0));
    final origin = await LoopbackOrigin.serve(dir.path)
      ..bytesPerSecond = 1000000;
    addTearDown(origin.close);
    await HttpOverrides.runWithHttpOverrides(() async {
      final client = HttpClient();
      addTearDown(client.close);
      final clock = Stopwatch()..start();
      final response = await (await client.getUrl(
        origin.urlOf('big.bin'),
      )).close();
      await response.drain<void>();
      // 200 kB at 1 MB/s: about 200 ms.
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(150));
    }, _Real());
  });

  group('stress items', () {
    const sources = [
      CorpusEntry(file: 'a.mp4', kind: CorpusKind.video),
      CorpusEntry(file: 'b.webm', kind: CorpusKind.loop),
      CorpusEntry(file: 'c.webp', kind: CorpusKind.animated),
    ];

    test('distinct items each take a key of their own', () {
      final items = StressItems(
        count: 9,
        sources: sources,
        kinds: CorpusKind.values.toSet(),
        distinct: true,
      );
      final keys = {for (var i = 0; i < 9; i++) items.keyAt(i)};
      expect(keys, hasLength(9));
      expect(StressItems.fileOf(items.keyAt(4)), 'b.webm');
    });

    test('shared items take one key per file', () {
      final items = StressItems(
        count: 9,
        sources: sources,
        kinds: CorpusKind.values.toSet(),
        distinct: false,
      );
      final keys = {for (var i = 0; i < 9; i++) items.keyAt(i)};
      expect(keys, hasLength(3));
      expect(items.keyAt(0), items.keyAt(3));
    });

    test('the kinds pick the sources', () {
      final items = StressItems(
        count: 4,
        sources: sources,
        kinds: parseKinds('loop,animated'),
        distinct: true,
      );
      expect(items.sources.map((s) => s.file), ['b.webm', 'c.webp']);
      expect(parseKinds(''), CorpusKind.values.toSet());
      expect(StressItems.fileOf(const MediaKey.remote('still')), isNull);
    });
  });
}
