import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_source.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// What every [UploadTransport] does, as a test group: run it against each
/// implementation (the fake, and each adapter over a local test server).
///
/// It drives the seam as the engine does: it opens a session, sends each
/// part's bytes as an [UploadPartBody] streamed from a file, and finishes.
/// [client] sends those bodies, for a transport whose parts go over HTTP;
/// without it a body's `send` throws. [received] reads back what the remote
/// end holds for a reference, when the test can, and the contract checks
/// it is the file's bytes.
abstract final class UploadTransportContract {
  /// Runs the contract against the transport [transport] builds, in a group
  /// named after [name].
  static void run(
    String name, {
    required UploadTransport Function() transport,
    HttpBytesClient Function()? client,
    Future<List<int>?> Function(RemoteRef ref)? received,
  }) {
    group('UploadTransportContract: $name', () {
      late UploadTransport subject;
      HttpBytesClient? http;

      setUp(() {
        subject = transport();
        http = client?.call();
      });

      Future<({UploadSource$Finished source, List<int> bytes})> file(
        int size,
      ) async {
        final bytes = [for (var i = 0; i < size; i++) (i * 31 + 7) & 0xff];
        return (source: await UploadSource.fromBytes(bytes), bytes: bytes);
      }

      UploadPartBody body(String path, int offset, int length) =>
          UploadPartBody(length, (
            url, {
            required method,
            required prefix,
            required suffix,
            headers,
            context,
          }) {
            final sender = http;
            if (sender == null) {
              throw StateError('The contract was given no client.');
            }
            return sender.upload(
              url,
              body: HttpBytesUploadBody.file(
                path,
                offset: offset,
                length: length,
                prefix: prefix,
                suffix: suffix,
              ),
              method: method,
              headers: headers,
              context: context,
            );
          });

      UploadInfo infoOf(int size) {
        final partSize = subject.capabilities.partSize(size);
        return UploadInfo(
          size: size,
          partSize: partSize,
          partCount: size == 0 ? 1 : (size + partSize - 1) ~/ partSize,
          fileName: 'contract.bin',
          contentType: 'application/octet-stream',
        );
      }

      Future<UploadPartAck> send(
        UploadSession session,
        UploadInfo info,
        String path,
        int index,
      ) {
        final offset = index * info.partSize;
        final length = index == info.partCount - 1
            ? info.size - offset
            : info.partSize;
        return session.sendPart(
          index,
          offset,
          body(path, offset, length),
          last: index == info.partCount - 1,
        );
      }

      Future<void> expectReceived(RemoteRef ref, List<int> bytes) async {
        final held = await received?.call(ref);
        if (held != null) expect(held, bytes);
      }

      /// A size of about two and a half parts, as the transport splits it.
      int severalParts() {
        final partSize = subject.capabilities.partSize(1);
        return 2 * partSize + partSize ~/ 2;
      }

      test('declares a positive part size for every size, and a budget '
          'that is not negative', () {
        for (final size in [0, 1, 10 * 1024 * 1024, 1024 * 1024 * 1024]) {
          expect(subject.capabilities.partSize(size), greaterThan(0));
        }
        expect(subject.capabilities.bytesInFlight, greaterThanOrEqualTo(0));
      });

      test('uploads a file of one part', () async {
        final (:source, :bytes) = await file(1000);
        final info = infoOf(source.size);
        final session = await subject.open(info);
        expect(session.resumed, isFalse);
        final acks = [
          for (var i = 0; i < info.partCount; i++)
            await send(session, info, source.path, i),
        ];
        final ref = await session.finish(source.size, acks);
        await expectReceived(ref, bytes);
      });

      test('uploads a file of several parts', () async {
        final (:source, :bytes) = await file(severalParts());
        final info = infoOf(source.size);
        final session = await subject.open(info);
        final acks = [
          for (var i = 0; i < info.partCount; i++)
            await send(session, info, source.path, i),
        ];
        final ref = await session.finish(source.size, acks);
        await expectReceived(ref, bytes);
      });

      test('acknowledges a part sent again, and the upload still '
          'finishes', () async {
        final (:source, :bytes) = await file(severalParts());
        final info = infoOf(source.size);
        final session = await subject.open(info);
        await send(session, info, source.path, 0);
        final acks = [
          for (var i = 0; i < info.partCount; i++)
            await send(session, info, source.path, i),
        ];
        final ref = await session.finish(source.size, acks);
        await expectReceived(ref, bytes);
      });

      test('a resumable transport reopens with its token and keeps the parts '
          'acknowledged before', () async {
        if (subject.capabilities.resume is UploadResume$None) {
          markTestSkipped('The transport does not resume.');
          return;
        }
        final (:source, :bytes) = await file(severalParts());
        final info = infoOf(source.size);
        final first = await subject.open(info);
        final token = first.resumeToken;
        expect(token, isNotNull);
        final kept = await send(first, info, source.path, 0);

        final second = await subject.open(info, resumeToken: token);
        expect(second.resumed, isTrue);
        final acks = [
          kept,
          for (var i = 1; i < info.partCount; i++)
            await send(second, info, source.path, i),
        ];
        final ref = await second.finish(source.size, acks);
        await expectReceived(ref, bytes);
      });

      test('a reference reads back from the journal equal', () async {
        final (:source, bytes: _) = await file(10);
        final info = infoOf(source.size);
        final session = await subject.open(info);
        final ref = await session.finish(source.size, [
          await send(session, info, source.path, 0),
        ]);
        final json = RemoteRef.codec.encode(ref)!;
        expect(RemoteRef.codec.decode(json), ref);
      });

      test('a separate thumbnail goes as an upload of its own, beside the '
          "item's", () async {
        if (subject.capabilities.thumbnail == UploadThumbnail.none) {
          markTestSkipped('The remote end makes its own thumbnail.');
          return;
        }
        final item = await file(severalParts());
        final thumbnail = await file(100);
        final itemInfo = infoOf(item.source.size);
        final thumbnailInfo = infoOf(thumbnail.source.size);
        final itemSession = await subject.open(itemInfo);
        final thumbnailSession = await subject.open(thumbnailInfo);
        final thumbnailRef = await thumbnailSession
            .finish(thumbnail.source.size, [
              for (var i = 0; i < thumbnailInfo.partCount; i++)
                await send(
                  thumbnailSession,
                  thumbnailInfo,
                  thumbnail.source.path,
                  i,
                ),
            ]);
        final itemRef = await itemSession.finish(item.source.size, [
          for (var i = 0; i < itemInfo.partCount; i++)
            await send(itemSession, itemInfo, item.source.path, i),
        ]);
        expect(itemRef, isNot(thumbnailRef));
        await expectReceived(itemRef, item.bytes);
        await expectReceived(thumbnailRef, thumbnail.bytes);
      });

      test('judges a reference it just answered good for reuse', () async {
        final (:source, bytes: _) = await file(10);
        final info = infoOf(source.size);
        final session = await subject.open(info);
        final ref = await session.finish(source.size, [
          await send(session, info, source.path, 0),
        ]);
        switch (subject.capabilities.reuse) {
          case UploadReuse$Lifetime(:final lifetime):
            expect(lifetime, greaterThanOrEqualTo(Duration.zero));
          case UploadReuse$Validity(:final isValid):
            expect(await isValid(ref), isTrue);
        }
      });
    });
  }
}
