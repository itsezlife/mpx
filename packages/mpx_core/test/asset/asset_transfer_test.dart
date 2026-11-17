import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const _key = MediaKey.remote('gif-1');
const _spec = AssetSpec(pixelWidth: 64, pixelHeight: 64);
const _small = AssetSpec(pixelWidth: 32, pixelHeight: 32);
const _profile = AssetProfile();
const _descriptor = MediaDescriptor(
  key: _key,
  kind: MediaKind.video,
  byteSize: 4000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAssetProducer producer;
  late AssetCacheScope scope;

  AssetCacheScope scopeWith({AutoDownloadPolicy? policy}) => AssetCacheScope(
    producer: producer,
    clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
    autoDownload: policy ?? AutoDownloadPolicy.always,
  );

  setUp(() {
    producer = FakeAssetProducer();
    scope = scopeWith();
  });
  tearDown(() => scope.dispose());

  group('a binding reads the transfer of its entry', () {
    test('none until the producer says otherwise', () {
      final binding = scope.attach(_key, _spec, _profile);

      expect(binding.transfer, AssetTransfer.none);
    });

    test('waiting, then the bytes, reach every binding of the entry', () {
      final first = scope.attach(_key, _spec, _profile);
      final second = scope.attach(_key, _spec, _profile);

      producer.last.waiting();
      expect(first.transfer, const AssetTransfer.waiting());

      producer.last.transfer(100, 400);
      expect(first.transfer, const AssetTransfer.receiving(100, 400));
      expect(second.transfer, const AssetTransfer.receiving(100, 400));
      expect(first.transfer.fraction, 0.25);
    });

    test('an unknown total falls back to the byte size of the content', () {
      final binding = scope.attach(_key, _spec, _profile);
      producer.last
        ..describe(_descriptor)
        ..waiting();
      expect(binding.transfer, const AssetTransfer.waiting(4000));

      producer.last.transfer(1000, null);

      expect(binding.transfer, const AssetTransfer.receiving(1000, 4000));
      expect(binding.transfer.fraction, 0.25);
    });

    test('a total the source announced wins over the byte size', () {
      final binding = scope.attach(_key, _spec, _profile);
      producer.last
        ..describe(_descriptor)
        ..transfer(100, 200);

      expect(binding.transfer, const AssetTransfer.receiving(100, 200));
    });

    test('a memory hit inside the attach never transfers', () {
      producer.onProduce = (attempt) => attempt.advance(AssetStage.full);

      final binding = scope.attach(_key, _spec, _profile);

      expect(binding.transfer, AssetTransfer.none);
    });

    test('the final stage ends it; a stand-in stage does not', () {
      final binding = scope.attach(_key, _spec, _profile);
      producer.last
        ..transfer(400, 400)
        ..advance(AssetStage.placeholder);
      expect(binding.transfer, const AssetTransfer.receiving(400, 400));

      producer.last.advance(AssetStage.full);

      expect(binding.transfer, AssetTransfer.none);
    });

    test('a detached binding reads none', () {
      final binding = scope.attach(_key, _spec, _profile);
      producer.last.waiting();

      binding.detach();

      expect(binding.transfer, AssetTransfer.none);
    });

    test('the last binding leaving forgets it', () {
      final binding = scope.attach(_key, _spec, _profile);
      producer.last
        ..transfer(100, 400)
        ..advance(AssetStage.placeholder)
        ..fail(StateError('offline'));
      binding.detach();

      final again = scope.attach(_key, _spec, _profile);

      expect(again.transfer, AssetTransfer.none);
    });
  });

  group('a failure', () {
    test('turns a download under way into failed and keeps the picture', () {
      final binding = scope.attach(_key, _spec, _profile);
      final thumbnail = producer.last.advance(AssetStage.placeholder);
      producer.last
        ..transfer(100, 400)
        ..fail(StateError('offline'));

      expect(
        binding.transfer,
        const AssetTransfer.failed(AssetFailureKind.transient, 100, 400),
      );
      expect(binding.readiness.stage, AssetStage.placeholder);
      expect(binding.paintable, same(thumbnail));
    });

    test('of content that was not downloading shows nothing', () {
      final binding = scope.attach(_key, _spec, _profile);

      producer.last.fail(
        StateError('bad data'),
        kind: AssetFailureKind.permanent,
      );

      expect(binding.transfer, AssetTransfer.none);
    });

    test('download() tries again', () {
      final binding = scope.attach(_key, _spec, _profile);
      producer.last
        ..waiting()
        ..fail(StateError('offline'));

      binding.download();

      expect(producer.attempts, hasLength(2));
      expect(producer.last.demand.autoDownload(_descriptor), AutoDownload.now);
    });

    test('a report after the attempt ended is ignored', () {
      final binding = scope.attach(_key, _spec, _profile);
      final attempt = producer.last..fail(StateError('offline'));

      attempt.transfer(10, 20);

      expect(binding.transfer, AssetTransfer.none);
    });
  });

  group('cancelDownload', () {
    test('stops the download, keeps the stages and awaits the user', () {
      final binding = scope.attach(_key, _spec, _profile);
      final first = producer.last..advance(AssetStage.preview);
      first.transfer(100, 400);

      binding.cancelDownload();

      expect(first.isCancelled, isTrue);
      expect(binding.transfer, const AssetTransfer.awaitingUser(400));
      expect(binding.readiness.stage, AssetStage.preview);
      // The next attempt only fetches the stand-ins.
      expect(producer.attempts, hasLength(2));
      expect(
        producer.last.demand.autoDownload(_descriptor),
        AutoDownload.manual,
      );
    });

    test('does nothing when no download is under way', () {
      final binding = scope.attach(_key, _spec, _profile);

      binding.cancelDownload();

      expect(producer.attempts, hasLength(1));
      expect(producer.last.isCancelled, isFalse);
    });

    test('is remembered for the key across detach and attach', () {
      final binding = scope.attach(_key, _spec, _profile);
      producer.last.waiting();
      binding
        ..cancelDownload()
        ..detach();

      final again = scope.attach(_key, _small, _profile);

      expect(
        producer.last.demand.autoDownload(_descriptor),
        AutoDownload.manual,
      );
      expect(producer.last.request.spec, _small);
      expect(again.transfer, AssetTransfer.none);
    });

    test('download() forgets it and downloads, whatever the policy', () {
      scope.dispose();
      scope = scopeWith(policy: FakeAutoDownloadPolicy());
      final binding = scope.attach(_key, _spec, _profile);
      producer.last
        ..describe(_descriptor)
        ..waiting();
      binding.cancelDownload();
      producer.last.awaitingUser();

      binding.download();

      expect(producer.attempts, hasLength(3));
      expect(producer.last.demand.autoDownload(_descriptor), AutoDownload.now);
    });

    test('connectivity does not restart a cancelled key', () {
      final binding = scope.attach(_key, _spec, _profile);
      producer.last.waiting();
      binding.cancelDownload();
      producer.last.fail(StateError('offline'));

      scope.connectivityRestored();

      expect(producer.attempts, hasLength(2));
    });
  });

  test('connectivity restarts a transient failure that is not cancelled', () {
    scope.attach(_key, _spec, _profile);
    producer.last
      ..waiting()
      ..fail(StateError('offline'));

    scope.connectivityRestored();

    expect(producer.attempts, hasLength(2));
  });

  testWidgets('byte reports are heard once per frame', (tester) async {
    final binding = scope.attach(_key, _spec, _profile);
    var signals = 0;
    binding.addListener(() => signals++);
    producer.last.waiting();
    expect(signals, 1);

    producer.last
      ..transfer(10, 400)
      ..transfer(20, 400)
      ..transfer(30, 400);
    expect(signals, 2);
    expect(binding.transfer, const AssetTransfer.receiving(30, 400));

    await tester.pump();
    expect(signals, 3);

    producer.last.transfer(40, 400);
    expect(signals, 4);
    await tester.pump();
    expect(signals, 4);
  });

  group('a content has one transfer through every spec of it', () {
    // A tile waits for the user at its own spec while a viewer downloads
    // the same bytes at another.
    late AssetBinding tile;
    late FakeAssetAttempt tileAttempt;

    setUp(() {
      tile = scope.attach(_key, _small, _profile);
      tileAttempt = producer.last
        ..describe(_descriptor)
        ..advance(AssetStage.preview)
        ..awaitingUser();
    });

    test('the tile shows the download another spec runs', () {
      var signals = 0;
      tile.addListener(() => signals++);
      final viewer = scope.attach(_key, _spec, _profile);
      producer.last.transfer(1000, 4000);

      expect(viewer.transfer, const AssetTransfer.receiving(1000, 4000));
      expect(tile.transfer, const AssetTransfer.receiving(1000, 4000));
      expect(signals, greaterThan(0));
    });

    test('content complete at one spec starts the others from the local '
        'bytes, and their transfer ends', () {
      scope.attach(_key, _spec, _profile);
      producer.last
        ..transfer(4000, 4000)
        ..advance(AssetStage.full);

      expect(tileAttempt.isCancelled, isTrue);
      final again = producer.attemptsFor(const AssetRequest(_key, _small)).last;
      expect(again, isNot(same(tileAttempt)));
      expect(tile.transfer, AssetTransfer.none);

      again.advance(AssetStage.full);
      expect(tile.readiness.stage, AssetStage.full);
      expect(tile.transfer, AssetTransfer.none);
    });

    test('a spec whose download stopped short starts again too', () {
      tile.download();
      producer.last
        ..transfer(1000, 4000)
        ..fail(StateError('offline'));
      expect(tile.transfer, isA<AssetTransfer$Failed>());

      scope.attach(_key, _spec, _profile);
      producer.last.advance(AssetStage.full);

      expect(
        producer.attemptsFor(const AssetRequest(_key, _small)),
        hasLength(3),
      );
      expect(tile.transfer, AssetTransfer.none);
    });

    test('a stand-in that is the best a spec makes starts nothing', () {
      scope.attach(_key, _spec, _profile);
      producer.last
        ..advance(AssetStage.placeholder)
        ..bestReached();

      expect(
        producer.attemptsFor(const AssetRequest(_key, _small)),
        hasLength(1),
      );
      expect(tile.transfer, const AssetTransfer.awaitingUser(4000));
    });

    test('cancel from the tile stops the download of the other spec', () {
      scope.attach(_key, _spec, _profile);
      final viewerAttempt = producer.last..transfer(1000, 4000);

      tile.cancelDownload();

      expect(viewerAttempt.isCancelled, isTrue);
      expect(tile.transfer, isA<AssetTransfer$AwaitingUser>());
    });
  });

  group('auto-download', () {
    late FakeAutoDownloadPolicy policy;
    const contacts = AutoDownloadContext.contacts;
    const channels = AutoDownloadContext.channels;

    setUp(() {
      scope.dispose();
      policy = FakeAutoDownloadPolicy()..byContext[contacts] = AutoDownload.now;
      scope = scopeWith(policy: policy);
    });

    test('the most permissive tag of the attached bindings wins', () {
      scope.attach(_key, _spec, _profile, downloadContext: channels);
      expect(
        producer.last.demand.autoDownload(_descriptor),
        AutoDownload.manual,
      );

      scope.attach(_key, _spec, _profile, downloadContext: contacts);

      expect(producer.last.demand.downloadContexts, {channels, contacts});
      expect(producer.last.demand.autoDownload(_descriptor), AutoDownload.now);
    });

    test('a permissive attach starts content awaiting the user', () {
      final channel = scope.attach(
        _key,
        _spec,
        _profile,
        downloadContext: channels,
      );
      producer.last
        ..describe(_descriptor)
        ..awaitingUser();

      final contact = scope.attach(
        _key,
        _spec,
        _profile,
        downloadContext: contacts,
      );

      expect(producer.attempts, hasLength(2));
      expect(producer.attempts.first.isCancelled, isTrue);
      producer.last.transfer(5, 10);
      // One entry, one transfer, whatever the tags.
      expect(channel.transfer, contact.transfer);
      expect(scope.entryCount, 1);
    });

    test('a policy change starts the content it now allows', () {
      final binding = scope.attach(
        _key,
        _spec,
        _profile,
        downloadContext: channels,
      );
      producer.last
        ..describe(_descriptor)
        ..awaitingUser();

      policy.byContext[channels] = AutoDownload.now;
      policy.changed();

      expect(producer.attempts, hasLength(2));
      expect(binding.transfer, AssetTransfer.none);
    });

    test('a policy change leaves a cancelled key alone', () {
      final binding = scope.attach(
        _key,
        _spec,
        _profile,
        downloadContext: contacts,
      );
      producer.last
        ..describe(_descriptor)
        ..waiting();
      binding.cancelDownload();
      producer.last.awaitingUser();

      policy.changed();

      expect(producer.attempts, hasLength(2));
    });

    test('a binding with no tag uses the default context', () {
      scope.attach(_key, _spec, _profile);

      expect(producer.last.demand.downloadContexts, {null});
      expect(
        producer.last.demand.autoDownload(_descriptor),
        AutoDownload.manual,
      );
    });

    test('without a descriptor the answer is now', () {
      scope.attach(_key, _spec, _profile, downloadContext: channels);

      expect(producer.last.demand.autoDownload(null), AutoDownload.now);
    });
  });
}
