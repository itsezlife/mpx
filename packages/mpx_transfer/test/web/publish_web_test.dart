// Publish jobs on the web from a picked file, over the three upload
// transports and a real origin private file system.
//
// Run with:
// flutter test --platform chrome test/web/publish_web_test.dart
//
// Browser only: Blob, fetch and OPFS do not exist on the VM, so this file
// stays out of test/unit_test.dart. The server runs on the VM beside the
// page (upload_server_hybrid.dart).
@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_storage_opfs_js.dart';
import 'package:mpx_transfer/testing.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web/web.dart' as web;

var _directories = 0;

/// A fresh OPFS directory of its own for one test, removed after it.
Future<web.FileSystemDirectoryHandle> _freshDirectory() async {
  final root = await web.window.navigator.storage.getDirectory().toDart;
  final name =
      'mpx_publish_test_${DateTime.now().microsecondsSinceEpoch}_'
      '${_directories++}';
  addTearDown(
    () => root
        .removeEntry(name, web.FileSystemRemoveOptions(recursive: true))
        .toDart,
  );
  return root
      .getDirectoryHandle(name, web.FileSystemGetDirectoryOptions(create: true))
      .toDart;
}

/// The upload server beside the page: its URL, and its requests.
final class _Server {
  _Server._(this._channel, this._answers, this.url);

  static Future<_Server> start() async {
    final channel = spawnHybridUri('/test/web/upload_server_hybrid.dart');
    final answers = StreamIterator(channel.stream);
    await answers.moveNext();
    final server = _Server._(channel, answers, answers.current! as String);
    addTearDown(() => channel.sink.close());
    return server;
  }

  final StreamChannel<Object?> _channel;
  final StreamIterator<Object?> _answers;
  final String url;
  int _next = 0;

  Future<Object?> ask(String op, [Map<String, Object?> fields = const {}]) {
    final id = _next++;
    _channel.sink.add({'id': id, 'op': op, ...fields});
    return () async {
      await _answers.moveNext();
      return (_answers.current! as Map<Object?, Object?>)['result'];
    }();
  }

  /// The bytes of file [id] as the server keeps it.
  Future<List<int>?> file(String id) async =>
      (await ask('file', {'file': id}) as List<Object?>?)?.cast<int>();

  Future<Map<String, Object?>> call(String method, String path, Object body) =>
      ask('call', {
        'method': method,
        'path': path,
        'body': jsonEncode(body),
      }).then((answer) {
        final reply = answer! as Map<Object?, Object?>;
        return jsonDecode(reply['body']! as String) as Map<String, Object?>;
      });
}

RemoteRef _idOf(HttpBytesResponse response) => RemoteRef(
  (jsonDecode(utf8.decode(response.body!)) as Map)['id']! as String,
);

List<UploadTransport> _transports(_Server server, HttpBytesClient client) => [
  MultipartUploadTransport(
    request: (_) =>
        MultipartUploadRequest(Uri.parse('${server.url}/multipart')),
    remoteRef: _idOf,
  ),
  TusUploadTransport(
    endpoint: Uri.parse('${server.url}/tus/'),
    client: client,
    partSize: (_) => 4,
  ),
  NumberedPartsTransport(
    smallPartSize: 4,
    start: (info) async =>
        (await server.call('POST', '/numbered/start', {
              'size': info.size,
              'parts': info.partCount,
            }))['uploadId']!
            as String,
    partRequest: (part) => NumberedPartRequest(
      Uri.parse('${server.url}/numbered/${part.uploadId}/${part.number}'),
    ),
    receiptOf: (response) => response.headers['x-part-id'],
    complete: (completion) async => RemoteRef(
      (await server.call('POST', '/numbered/${completion.uploadId}/complete', {
            'parts': [
              for (final part in completion.parts)
                {'number': part.number, 'id': part.receipt},
            ],
          }))['file']!
          as String,
    ),
  ),
];

/// A file the user picked: [bytes], named `picked.bin`.
SourceBytes _picked(List<int> bytes) => SourceBytes.blob(
  web.File([Uint8List.fromList(bytes).toJS].toJS, 'picked.bin'),
);

PublishItem _item(List<int> bytes) => PublishItem(
  itemId: 'a',
  key: MediaKey.local('00000000-0000-4000-8000-000000000001'),
  source: PublishSource.prepared(
    PreparedMedia(
      kind: PreparedKind.file,
      path: 'picked.bin',
      isOriginal: true,
      byteSize: bytes.length,
    ),
  ),
  pageSource: _picked(bytes),
);

Future<PublishItemState> _settled(PublishJob job) async {
  for (var i = 0; i < 400; i++) {
    final state = job.snapshot.item('a')!.state;
    if (state is PublishItemState$Uploaded ||
        state is PublishItemState$Failed) {
      return state;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return job.snapshot.item('a')!.state;
}

void main() {
  late RecordingDiagnostics recorder;
  late _Server server;
  late HttpBytesClient client;
  late UploadSourceCopies copies;

  setUp(() async {
    recorder = RecordingDiagnostics.install();
    server = await _Server.start();
    client = HttpBytesClient();
    addTearDown(client.close);
    copies = await UploadSourceCopies$Opfs$JS.open(await _freshDirectory());
  });

  Future<UploadsHarness> harness({
    Future<void> Function(Duration delay)? wait,
  }) async {
    final built = await UploadsHarness.open(
      lifecycle: ManualPlaybackLifecycleSource(
        initial: AppLifecycleState.resumed,
      ),
      transports: _transports(server, client),
      client: client,
      sourceCopies: copies,
      progressInterval: Duration.zero,
      wait: wait ?? (_) async {},
    );
    addTearDown(() => built.transfers.dispose());
    return built;
  }

  final bytes = [for (var i = 0; i < 10; i++) (i * 13 + 5) & 0xff];

  for (final transport in ['multipart', 'tus', 'numberedParts']) {
    test('a picked file uploads through $transport', () async {
      final h = await harness();
      final job = h.transfers.upload(_item(bytes), transport: transport);
      final state = await _settled(job);

      expect(state, isA<PublishItemState$Uploaded>());
      final ref = (state as PublishItemState$Uploaded).file!;
      expect(await server.file(ref.id), bytes);
      expect(
        recorder.whereOp(JournalOp.sourceCopied).single.fields['bytes'],
        10,
      );
      expect(recorder.errors, isEmpty);
    });
  }

  /// Starts a tus upload of [bytes] whose first part breaks off after 4
  /// bytes, its retry held: a tab about to be reloaded mid upload.
  Future<(UploadsHarness, PublishJob, void Function())> brokenOff() async {
    var holding = true;
    final h = await harness(
      wait: (_) => holding ? Completer<void>().future : Future.value(),
    );
    final broke = server.ask('breakAt', {'bytes': 4});
    final job = h.transfers.upload(_item(bytes), transport: 'tus');
    await broke;
    await server.ask('release');
    await h.transfers.debugSourcesCopied;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await h.settle();
    return (h, job, () => holding = false);
  }

  test('a reload mid upload resumes from the OPFS copy', () async {
    final (h, job, release) = await brokenOff();
    expect(copies.held, hasLength(1));

    recorder.clear();
    release();
    await h.kill();
    final state = await _settled(h.transfers.publishJob(job.id)!);

    expect(state, isA<PublishItemState$Uploaded>());
    final ref = (state as PublishItemState$Uploaded).file!;
    expect(await server.file(ref.id), bytes);
    expect(
      recorder.whereOp(TransportOp.resumeDecision).single.fields,
      containsPair('outcome', 'resumed'),
    );
    expect(recorder.whereOp(JournalOp.sourceLost), isEmpty);
  });

  test('a reload that finds the copy gone reads sourceLost; a retry with '
      'the file picked again uploads it', () async {
    final (h, job, release) = await brokenOff();
    // The browser cleared the site's storage.
    await copies.delete(copies.held.single);

    recorder.clear();
    release();
    await h.kill();
    final reloaded = h.transfers.publishJob(job.id)!;
    final lost = await _settled(reloaded);
    expect(
      lost,
      isA<PublishItemState$Failed>().having(
        (s) => s.reason,
        'reason',
        'sourceLost',
      ),
    );
    expect(recorder.whereOp(JournalOp.sourceLost), hasLength(1));

    final again = [for (var i = 0; i < 7; i++) i];
    expect(reloaded.retryItem('a', source: _picked(again)), isTrue);
    final state = await _settled(reloaded);
    expect(state, isA<PublishItemState$Uploaded>());
    final ref = (state as PublishItemState$Uploaded).file!;
    expect(await server.file(ref.id), again);
  });
}
