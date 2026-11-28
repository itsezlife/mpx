import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _content = MediaKey.remote('clip-1');
final _source = MediaKey.local('0f8fad5b-d9cb-469f-a165-70867728950e');

void main() {
  // A test's own engine over the fake: each step moves every running job by
  // a chunk, as a real engine would report.
  TrackedTransfersHarness harness() {
    final fake = FakeTrackedTransfers();
    final paused = <MediaKey>{};
    return TrackedTransfersHarness(
      transfers: fake,
      content: _content,
      uploadSource: _source,
      advance: () async {
        for (final key in [_content, _source]) {
          if (paused.contains(key)) continue;
          switch (fake.valueOf(key)) {
            case AssetTransfer$Waiting() when key == _content:
              fake.drive(key, const AssetTransfer.receiving(0, 400));
            case AssetTransfer$Receiving(:final received) when received < 400:
              fake.drive(key, AssetTransfer.receiving(received + 100, 400));
            case AssetTransfer$Receiving():
              fake
                ..setFile(key, '/cache/clip-1')
                ..drive(key, AssetTransfer.none);
            case AssetTransfer$Waiting():
              fake.drive(key, const AssetTransfer.sending(0, 300));
            case AssetTransfer$Sending(:final sent) when sent < 300:
              fake.drive(key, AssetTransfer.sending(sent + 100, 300));
            case AssetTransfer$Sending():
              fake.drive(key, AssetTransfer.sent);
            default:
              break;
          }
        }
      },
      interrupt: (key) async => paused.add(key),
      resumeInterrupted: (key) async => paused.remove(key),
      startUpload: () async =>
          fake.drive(_source, const AssetTransfer.waiting(300)),
      publish: () async => fake.drive(_source, AssetTransfer.none),
    );
  }

  TrackedTransfersContract.run(harness);

  group('FakeTrackedTransfers', () {
    late FakeTrackedTransfers fake;

    setUp(() => fake = FakeTrackedTransfers());

    test('records download, cancel and lease calls', () async {
      fake
        ..download(_content, origin: TransferOrigin.auto)
        ..download(_content)
        ..cancel(_content);
      await fake.leaseFile(_content);

      expect(fake.downloads, [
        (key: _content, origin: TransferOrigin.auto),
        (key: _content, origin: TransferOrigin.user),
      ]);
      expect(fake.cancels, [_content]);
      expect(fake.leaseRequests, [_content]);
    });

    test('drives any value per key, heard by every watcher', () {
      final first = fake.watch(_content);
      final second = fake.watch(_content);
      final heard = <AssetTransfer>[];
      first.addListener(() => heard.add(first.value));

      fake.drive(_content, const AssetTransfer.sending(10, 20));

      expect(second.value, const AssetTransfer.sending(10, 20));
      expect(heard, [const AssetTransfer.sending(10, 20)]);
      expect(fake.watch(_source).value, AssetTransfer.none);
    });

    test('tells whether a key is watched', () {
      final watched = fake.watch(_content);
      void listener() {}

      expect(fake.isWatched(_content), isFalse);
      watched.addListener(listener);
      expect(fake.isWatched(_content), isTrue);
      watched.removeListener(listener);
      expect(fake.isWatched(_content), isFalse);
    });

    test('lends a file it was given, and counts the leases held', () async {
      fake.setFile(_content, '/cache/clip-1');

      final lease = await fake.leaseFile(_content);
      expect(lease!.path, '/cache/clip-1');
      expect(fake.leasesHeld, 1);

      await lease.release();
      expect(fake.leasesHeld, 0);
    });

    test('an upload cancel is only recorded', () {
      fake
        ..drive(_source, const AssetTransfer.sending(10, 20))
        ..cancel(_source);

      expect(fake.valueOf(_source), const AssetTransfer.sending(10, 20));
      expect(fake.cancels, [_source]);
    });
  });

  group('ContentFileLease', () {
    test('releases once', () async {
      var released = 0;
      final lease = ContentFileLease(
        path: '/cache/clip-1',
        onRelease: () async => released++,
      );

      await lease.release();
      await lease.release();

      expect(released, 1);
      expect(lease.isReleased, isTrue);
    });

    test('keeps its path out of toString', () {
      final lease = ContentFileLease(
        path: '/home/me/secret.mp4',
        onRelease: () async {},
      );

      expect(lease.toString(), isNot(contains('secret')));
    });
  });

  group('AssetTransfer.sending and sent', () {
    test('carry their bytes, fraction, equality and toString', () {
      const sending = AssetTransfer.sending(25, 100);

      expect(sending.fraction, 0.25);
      expect(sending.total, 100);
      expect(sending, const AssetTransfer.sending(25, 100));
      expect(sending, isNot(const AssetTransfer.sending(26, 100)));
      expect(sending, isNot(const AssetTransfer.receiving(25, 100)));
      expect(sending.hashCode, const AssetTransfer.sending(25, 100).hashCode);
      expect(sending.toString(), 'AssetTransfer.sending(25, 100)');
      expect(const AssetTransfer.sending(5).fraction, isNull);
      expect(AssetTransfer.sent.toString(), 'AssetTransfer.sent');
      expect(AssetTransfer.sent.fraction, isNull);
    });

    test('are not downloads', () {
      expect(const AssetTransfer.sending(1, 2).isActive, isFalse);
      expect(AssetTransfer.sent.isActive, isFalse);
    });
  });
}
