import 'dart:convert';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support/multipart_protocol.dart';
import '../support/upload_test_server.dart';

/// A map matcher holding every entry of [entries], and maybe more.
Matcher including(Map<String, Object> entries) => allOf([
  for (final MapEntry(:key, :value) in entries.entries)
    containsPair(key, value),
]);

void main() {
  late UploadTestServer server;
  late MultipartProtocol protocol;
  late HttpBytesClient client;

  setUp(() async {
    server = await UploadTestServer.start();
    protocol = MultipartProtocol(server);
    client = HttpBytesClient();
  });

  tearDown(() async {
    await client.close();
    await server.close();
  });

  RemoteRef idOf(HttpBytesResponse response) {
    final json = jsonDecode(utf8.decode(response.body!)) as Map;
    return RemoteRef(json['id']! as String);
  }

  MultipartUploadTransport multipart({
    MultipartUploadRequest Function(UploadInfo info)? request,
    RemoteRef Function(HttpBytesResponse response)? remoteRef,
  }) => MultipartUploadTransport(
    request: request ?? (_) => MultipartUploadRequest(protocol.url),
    remoteRef: remoteRef ?? idOf,
  );

  UploadTransportContract.run(
    'MultipartUploadTransport over a local server',
    transport: multipart,
    client: () => client,
    received: (ref) async => server.files[ref.id],
  );

  test('declares one part of the whole file, no resume, no thumbnail, a '
      'known size, a day of reuse', () {
    final capabilities = multipart().capabilities;
    expect(capabilities.partSize(0), 1);
    expect(capabilities.partSize(1), 1);
    expect(capabilities.partSize(3 << 30), 3 << 30);
    expect(capabilities.bytesInFlight, 0);
    expect(capabilities.resume, isA<UploadResume$None>());
    expect(capabilities.knownSizeRequired, isTrue);
    expect(capabilities.headLastAllowed, isFalse);
    expect(capabilities.thumbnail, UploadThumbnail.none);
    expect(
      (capabilities.reuse as UploadReuse$Lifetime).lifetime,
      const Duration(hours: 24),
    );
    expect(MultipartUploadTransport.defaultReuse, capabilities.reuse);
    expect(multipart().id, 'multipart');
  });

  group('through the upload engine', () {
    late RecordingDiagnostics recorder;
    final bytes = [for (var i = 0; i < 200 * 1024; i++) (i * 7 + 3) & 0xff];

    setUp(() => recorder = RecordingDiagnostics.install());

    Future<UploadsHarness> uploads(UploadTransport transport) async {
      final built = await UploadsHarness.open(
        lifecycle: ManualPlaybackLifecycleSource(
          initial: AppLifecycleState.resumed,
        ),
        transports: [transport],
        client: client,
        wait: (_) async {},
      );
      addTearDown(() => built.transfers.dispose());
      return built;
    }

    Future<TransferState> settled(UploadsHarness h, TransferId id) => h
        .transfers
        .watch()
        .map((jobs) => jobs.firstWhere((job) => job.id == id).state)
        .firstWhere(
          (state) =>
              state is TransferState$Completed || state is TransferState$Failed,
        )
        .timeout(const Duration(seconds: 20));

    test('the server receives the exact bytes, the form fields, the file '
        "part's name and type, and the request's headers", () async {
      final h = await uploads(
        multipart(
          request: (info) => MultipartUploadRequest(
            protocol.url,
            headers: const {'authorization': 'Bearer secret'},
            fields: const {'chat': '42', 'caption': 'a "quoted"\nline é'},
            fileField: 'media',
          ),
        ),
      );
      final id = h.upload(
        await UploadSource.fromBytes(bytes),
        fileName: 'photo.jpg',
        contentType: 'image/jpeg',
      );

      expect(
        await settled(h, id),
        TransferState.completed(RemoteRef('file-1')),
      );
      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.headers['authorization'], 'Bearer secret');
      final form = protocol.forms.single;
      expect(form.fields, {'chat': '42', 'caption': 'a "quoted"\nline é'});
      expect(form.fileField, 'media');
      expect(form.fileName, 'photo.jpg');
      expect(form.contentType, 'image/jpeg');
      expect(server.files['file-1'], bytes);

      expect(recorder.whereCategory('transport'), [
        isMpxEvent(
          level: MpxEventLevel.debug,
          op: TransportOp.sessionOpened,
          jobId: id,
          fields: {
            'transport': 'multipart',
            'resumed': false,
            'offset': 0,
            'size': bytes.length,
          },
        ),
        isMpxEvent(
          op: TransportOp.partSent,
          jobId: id,
          fields: including({'index': 0, 'offset': 0, 'bytes': bytes.length}),
        ),
        isMpxEvent(
          op: TransportOp.partAcked,
          jobId: id,
          fields: including({'index': 0}),
        ),
        isMpxEvent(
          level: MpxEventLevel.info,
          op: TransportOp.finished,
          jobId: id,
          fields: including({'finalSize': bytes.length, 'parts': 1}),
        ),
      ]);
      // No URL, header, field, file name or answer reaches an event.
      final text = [
        for (final event in recorder.events) ...event.fields.values,
      ].join(' ');
      for (final leak in [
        '127.0.0.1',
        'multipart/form',
        'secret',
        'quoted',
        'photo',
        'file-1',
      ]) {
        expect(text, isNot(contains(leak)));
      }
    });

    test('a 5xx is tried again, and the upload completes', () async {
      server.failNext([503]);
      final h = await uploads(multipart());
      final id = h.upload(await UploadSource.fromBytes(bytes));

      expect(await settled(h, id), isA<TransferState$Completed>());
      expect(server.requests, hasLength(2));
      expect(server.requests.last.body, hasLength(greaterThan(bytes.length)));
      expect(server.files.values.single, bytes);
      expect(recorder.whereOp(TransportOp.partRetry), [
        isMpxEvent(
          level: MpxEventLevel.warning,
          jobId: id,
          fields: including({
            'step': 'part',
            'index': 0,
            'attempt': 1,
            'status': 503,
          }),
        ),
      ]);
    });

    test('a 4xx fails the upload at once, not retryable', () async {
      server.failNext([400]);
      final h = await uploads(multipart());
      final id = h.upload(await UploadSource.fromBytes(bytes));

      expect(
        await settled(h, id),
        isA<TransferState$Failed>()
            .having((state) => state.kind, 'kind', TransferFailureKind.server)
            .having((state) => state.retryable, 'retryable', isFalse),
      );
      expect(server.requests, hasLength(1));
      expect(recorder.whereOp(TransportOp.partGaveUp), [
        isMpxEvent(
          level: MpxEventLevel.error,
          jobId: id,
          fields: {'step': 'part', 'index': 0, 'attempts': 1, 'status': 400},
        ),
      ]);
    });

    test('an answer the host cannot read fails the upload, reported, with '
        'no try again', () async {
      final h = await uploads(
        multipart(remoteRef: (_) => throw const FormatException('no id')),
      );
      final id = h.upload(await UploadSource.fromBytes(bytes));

      expect(
        await settled(h, id),
        isA<TransferState$Failed>().having(
          (state) => state.retryable,
          'retryable',
          isFalse,
        ),
      );
      expect(server.requests, hasLength(1));
      expect(recorder.whereOp(TransportOp.partGaveUp), [
        isMpxEvent(
          level: MpxEventLevel.error,
          jobId: id,
          fields: including({'step': 'part', 'code': 'unreadable_answer'}),
        ),
      ]);
    });

    test('a kill while the request is out, then a restart, sends the whole '
        'file again from byte 0', () async {
      server.holdNext();
      final h = await uploads(multipart());
      final id = h.upload(await UploadSource.fromBytes(bytes));
      while (server.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final first = server.requests.single.body;

      await h.kill();

      expect(await settled(h, id), isA<TransferState$Completed>());
      expect(server.requests, hasLength(2));
      // The same form again, the file whole: nothing was kept from the
      // request the kill cut off.
      expect(server.requests.last.body.length, first.length);
      expect(
        recorder.whereOp(TransportOp.partSent).last,
        isMpxEvent(fields: including({'offset': 0, 'bytes': bytes.length})),
      );
      expect(server.files.values.single, bytes);
      expect(
        recorder.whereOp(TransportOp.sessionOpened).last,
        isMpxEvent(fields: including({'resumed': false, 'offset': 0})),
      );
    });
  });
}
