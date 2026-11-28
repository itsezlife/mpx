import 'dart:io' show HttpOverrides;
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support/tus_protocol.dart';
import '../support/upload_test_server.dart';

/// 256 KiB: parts large against a socket's chunks, so a body broken off
/// at a byte count stops inside the part that held it.
const int _part = 256 * 1024;

List<int> _bytes(int size) => [
  for (var i = 0; i < size; i++) (i * 7 + 3) & 0xff,
];

void main() {
  late UploadTestServer http;
  late TusProtocol server;
  late HttpBytesClient client;
  late DateTime now;

  setUp(() async {
    // A widget test binding, once any test in the process made one, answers
    // every request of this isolate's HTTP client with 400. The tus
    // control calls run here (the parts on the transfer worker), so the
    // client is made with the real one, and the override put back.
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
    http = await UploadTestServer.start();
    server = TusProtocol(http);
    client = HttpBytesClient();
    now = DateTime.now().toUtc();
  });

  tearDown(() async {
    await client.close();
    await http.close();
  });

  TusUploadTransport tus({int part = _part, Map<String, String>? metadata}) =>
      TusUploadTransport(
        endpoint: server.endpoint,
        client: client,
        partSize: (_) => part,
        metadata: metadata ?? const {},
        now: () => now,
      );

  Future<UploadsHarness> harness(
    TusUploadTransport transport, {
    Duration progressInterval = Transfers.defaultProgressInterval,
  }) async {
    final h = await UploadsHarness.open(
      lifecycle: ManualPlaybackLifecycleSource(
        initial: AppLifecycleState.resumed,
      ),
      transports: [transport],
      client: client,
      progressInterval: progressInterval,
      now: () => now,
      wait: (_) async {},
    );
    addTearDown(() => h.transfers.dispose());
    return h;
  }

  Future<TransferState> settled(Transfers transfers, TransferId id) => transfers
      .watch()
      .map((jobs) => jobs.firstWhere((job) => job.id == id).state)
      .firstWhere(
        (state) =>
            state is TransferState$Completed || state is TransferState$Failed,
      )
      .timeout(const Duration(seconds: 20));

  String urlOf(TransferState state) =>
      ((state as TransferState$Completed).result as RemoteRef).id;

  group('contract', () {
    UploadTransportContract.run(
      'TusUploadTransport over a local tus server',
      transport: () => tus(part: 1000),
      client: () => client,
      received: (ref) async => server.uploadAt(ref.id)?.bytes.toBytes(),
    );
  });

  test('declares sequential parts, resume until the server expiry, a known '
      'size, no thumbnail and a reuse check against the server', () {
    final capabilities = tus().capabilities;
    expect(capabilities.bytesInFlight, 0);
    expect(capabilities.resume, isA<UploadResume$ServerExpiry>());
    expect(capabilities.knownSizeRequired, isTrue);
    expect(capabilities.headLastAllowed, isFalse);
    expect(capabilities.thumbnail, UploadThumbnail.none);
    expect(capabilities.reuse, isA<UploadReuse$Validity>());
    expect(TusUploadTransport.defaultPartSize(1000), 1024 * 1024);
    expect(TusUploadTransport.defaultPartSize(64 * 1024 * 1024), 4 << 20);
  });

  test('creates the upload with its length and metadata, patches each part '
      'at the server offset, and completes with the upload URL', () async {
    final recorder = RecordingDiagnostics.install();
    final bytes = _bytes(2 * _part + 1000);
    final h = await harness(tus(metadata: const {'chat': 'c1'}));
    final id = h.upload(
      await UploadSource.fromBytes(bytes),
      fileName: 'photo.jpg',
      contentType: 'image/jpeg',
    );
    final state = await settled(h.transfers, id);

    final url = urlOf(state);
    final upload = server.uploadAt(url)!;
    expect(upload.length, bytes.length);
    expect(upload.metadata, {
      'filename': 'photo.jpg',
      'filetype': 'image/jpeg',
      'chat': 'c1',
    });
    expect(upload.bytes.toBytes(), bytes);
    expect(server.requests.first, 'POST ${server.path}');
    expect(
      [for (final patch in server.patches) patch.offset],
      [0, _part, 2 * _part],
    );
    expect(Uri.parse(url).host, server.endpoint.host);
    expect(
      (state as TransferState$Completed).result,
      isA<RemoteRef>().having(
        (ref) => ref.attributes[TusUploadTransport.uploadUrlAttribute],
        'upload attribute',
        url,
      ),
    );
    expect(recorder.errors, isEmpty);
    expect(
      recorder.whereOp(TransportOp.sessionOpened).single,
      isMpxEvent(
        fields: {
          'transport': 'tus',
          'resumed': false,
          'offset': 0,
          'size': bytes.length,
        },
      ),
    );
  });

  test('after a kill the restarted engine reads the server offset and sends '
      'only the rest, though the journal kept no part', () async {
    final recorder = RecordingDiagnostics.install();
    final bytes = _bytes(2 * _part + _part ~/ 2);
    // No progress window closes before the kill: the journal keeps the
    // session's token from its state write, and no part.
    final h = await harness(tus(), progressInterval: const Duration(hours: 1));
    server.breakAt = _part + 1000;
    final id = h.upload(await UploadSource.fromBytes(bytes));
    await server.broke.future;
    await h.settle();
    final upload = server.uploads.values.single;
    final held = upload.offset;
    expect(held, inInclusiveRange(_part + 1000, 2 * _part - 1));
    final patchesBefore = server.patches.length;

    await h.kill();
    expect(h.uploadOf(id)!.parts, isEmpty);
    expect(h.uploadOf(id)!.resumeToken, isNotNull);
    final state = await settled(h.transfers, id);
    server.release.complete();

    expect(urlOf(state), endsWith(upload.path));
    expect(server.uploads, hasLength(1), reason: 'no new upload');
    expect(upload.bytes.toBytes(), bytes);
    final after = server.patches.skip(patchesBefore).toList();
    expect([for (final patch in after) patch.offset], [held, 2 * _part]);
    expect(
      after.fold(0, (sum, patch) => sum + patch.received),
      bytes.length - held,
      reason: 'only the bytes the server lacked went again',
    );
    expect(
      recorder.whereOp(TransportOp.sessionOpened).last,
      isMpxEvent(
        jobId: id,
        fields: {
          'transport': 'tus',
          'resumed': true,
          'offset': held,
          'size': bytes.length,
        },
      ),
    );
  });

  group('starts again from zero, not failing, when the server', () {
    Future<void> restartsFromZero(
      void Function(String uploadUrl) breakIt,
    ) async {
      final recorder = RecordingDiagnostics.install();
      final bytes = _bytes(2 * _part);
      final h = await harness(tus());
      server.breakAt = _part + 1000;
      final id = h.upload(await UploadSource.fromBytes(bytes));
      await server.broke.future;
      await h.settle();
      final first = server.uploads.values.single;
      breakIt('${server.endpoint.resolve(first.path)}');

      await h.kill();
      final state = await settled(h.transfers, id);
      server.release.complete();

      expect(state, isA<TransferState$Completed>());
      final url = urlOf(state);
      expect(Uri.parse(url).path, isNot(first.path));
      expect(server.uploadAt(url)!.bytes.toBytes(), bytes);
      expect(
        server.requests.where((request) => request.startsWith('POST')),
        hasLength(2),
      );
      expect(
        recorder.whereOp(TransportOp.sessionOpened).last,
        isMpxEvent(fields: containsPair('resumed', false)),
      );
      expect(recorder.errors, isEmpty);
    }

    test('says the upload expired (Upload-Expires in the past)', () async {
      server.expiresAt = () => now.add(const Duration(hours: 1));
      await restartsFromZero((url) {
        server.uploadAt(url)!.expiresAt = now.subtract(
          const Duration(minutes: 1),
        );
      });
    });

    test('answers 404 on resume', () async {
      await restartsFromZero((url) => server.forget(url));
    });

    test('answers 410 on resume', () async {
      await restartsFromZero((url) => server.forget(url, status: 410));
    });
  });

  test('a part broken off mid-body is retried from the server offset after '
      'a HEAD, reported as a retry', () async {
    final recorder = RecordingDiagnostics.install();
    final bytes = _bytes(2 * _part);
    final h = await harness(tus());
    server.breakAt = 1000;
    final id = h.upload(await UploadSource.fromBytes(bytes));
    await server.broke.future;
    final held = server.uploads.values.single.offset;
    server.release.complete();
    final state = await settled(h.transfers, id);

    expect(server.uploadAt(urlOf(state))!.bytes.toBytes(), bytes);
    expect(
      [for (final patch in server.patches) patch.offset],
      [0, held, _part],
    );
    expect(server.requests, contains(startsWith('HEAD')));
    expect(
      recorder.whereOp(TransportOp.partRetry).single,
      isMpxEvent(
        level: MpxEventLevel.warning,
        jobId: id,
        fields: allOf(containsPair('index', 0), containsPair('attempt', 1)),
      ),
    );
    expect(recorder.errors, isEmpty);
  });

  test('a 409 offset conflict asks the offset again and goes on', () async {
    final recorder = RecordingDiagnostics.install();
    final bytes = _bytes(1000);
    final h = await harness(tus());
    server.patchStatuses.add(409);
    final id = h.upload(await UploadSource.fromBytes(bytes));
    final state = await settled(h.transfers, id);

    expect(server.uploadAt(urlOf(state))!.bytes.toBytes(), bytes);
    expect(
      recorder.whereOp(TransportOp.partRetry).single,
      isMpxEvent(fields: containsPair('status', 409)),
    );
  });

  test('a refused part fails the upload without a retry, its event '
      'carrying the status and no URL', () async {
    final recorder = RecordingDiagnostics.install();
    final h = await harness(tus());
    server.patchStatuses.add(403);
    final id = h.upload(await UploadSource.fromBytes(_bytes(1000)));
    final state = await settled(h.transfers, id);

    expect(
      state,
      isA<TransferState$Failed>().having(
        (failed) => failed.retryable,
        'retryable',
        isFalse,
      ),
    );
    expect(recorder.whereOp(TransportOp.partRetry), isEmpty);
    expect(
      recorder.whereOp(TransportOp.partGaveUp).single,
      isMpxEvent(
        level: MpxEventLevel.error,
        jobId: id,
        fields: allOf(containsPair('status', 403), containsPair('index', 0)),
      ),
    );
    for (final event in recorder.events) {
      for (final value in event.fields.values) {
        expect('$value', isNot(contains(server.endpoint.host)));
        expect('$value', isNot(contains(server.path)));
      }
    }
  });

  test('a session tells the server expiry, and a resume past it starts a '
      'new upload', () async {
    final expires = DateTime.utc(2030, 1, 2, 3, 4, 5);
    server.expiresAt = () => expires;
    final transport = tus(part: 100);
    const info = UploadInfo(size: 300, partSize: 100, partCount: 3);
    final session = await transport.open(info);
    expect(session.resumeExpiresAt, expires);

    final reopened = await transport.open(
      info,
      resumeToken: session.resumeToken,
    );
    expect(reopened.resumed, isTrue);
    expect((reopened as UploadOffsetSession).remoteOffset, 0);

    now = expires.add(const Duration(seconds: 1));
    final late = await transport.open(info, resumeToken: session.resumeToken);
    expect(late.resumed, isFalse);
    expect(late.resumeToken, isNot(session.resumeToken));
  });

  test('a reference is good for reuse while the server holds the whole '
      'upload', () async {
    final bytes = _bytes(1000);
    final transport = tus();
    final h = await harness(transport);
    final id = h.upload(await UploadSource.fromBytes(bytes));
    final ref =
        (await settled(h.transfers, id) as TransferState$Completed).result
            as RemoteRef;
    final reuse = transport.capabilities.reuse as UploadReuse$Validity;

    expect(await reuse.isValid(ref), isTrue);
    server.forget(ref.id, status: 410);
    expect(await reuse.isValid(ref), isFalse);
  });
}
