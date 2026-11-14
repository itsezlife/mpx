import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_example/lab/corpus.dart';
import 'package:mpx_example/lab/lab_net.dart';

void main() {
  test('a public entry stays without a local file', () async {
    final dir = Directory.systemTemp.createTempSync('lab_net');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/manifest.json').writeAsStringSync(
      jsonEncode({
        'entries': [
          {
            'file': 'trailer.mp4',
            'kind': 'video',
            'url': 'https://example.org/media/trailer.mp4',
          },
          {'file': 'missing.webm', 'kind': 'loop'},
        ],
      }),
    );
    final corpus = (await Corpus.load(dir.path))!;
    expect(corpus.entries.map((e) => e.file), ['trailer.mp4']);
    expect(corpus.entryOf('trailer.mp4')!.url!.host, 'example.org');
    expect(Corpus.hasFile(dir.path, corpus.entries.single), isFalse);
    expect(corpus.entries.single.describe(), endsWith('example.org'));
  });

  test('the recorder counts every request and names an agent', () async {
    final agents = <String?>[];
    final recorder = NetRecorder(
      MockClient((request) async {
        agents.add(request.headers['user-agent']);
        return http.Response.bytes(List.filled(1000, 0), 200);
      }),
    );
    for (final file in ['a.mp4', 'a.mp4', 'b.gif']) {
      final response = await recorder.send(
        http.Request('GET', Uri.parse('https://example.org/$file')),
      );
      await response.stream.drain<void>();
    }
    expect(agents, everyElement(NetRecorder.userAgent));
    final report = recorder.report(entries: 5);
    expect(report.first, startsWith('net requests=3 failed=0 bytes=3000 '));
    expect(report.first, contains('files=2 of 5 entries'));
    expect(report.skip(1), hasLength(2));
    expect(report[1], contains('net file a.mp4 host=example.org requests=2'));
  });

  test('a transfer the worker ran counts as a request', () {
    final recorder =
        NetRecorder(MockClient((_) async => http.Response('', 200)))
          ..recordTransfer(
            HttpBytesTransferRecord(
              url: Uri.parse('http://127.0.0.1:1/clip.mp4'),
              range: 'bytes=0-',
              statusCode: 206,
              started: DateTime(2026),
              head: const Duration(milliseconds: 12),
              ended: const Duration(milliseconds: 80),
              bytes: 4000,
              failed: false,
            ),
          );

    final request = recorder.requests.single;
    expect(request.range, 'bytes=0-');
    expect(request.status, 206);
    expect(request.bytes, 4000);
    expect(request.firstByte, const Duration(milliseconds: 12));
    expect(request.done, const Duration(milliseconds: 80));
    expect(recorder.report(entries: 1).first, contains('bytes=4000'));
  });
}
