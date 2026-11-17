import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

import 'pipeline_harness.dart';

MediaDescriptor _video(int n, {bool thumbnail = true}) => MediaDescriptor(
  key: MediaKey.remote('video-$n'),
  kind: MediaKind.still,
  byteSize: 4000,
  thumbnail: thumbnail ? MediaThumbnailRef('thumb-$n') : null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the fetcher reports the transfer of the content', () {
    test('received bytes over the total reach the binding', () {
      final item = sticker(1);
      final harness = PipelineHarness(known: [item], autoFetch: false);
      addTearDown(harness.dispose);
      final binding = harness.attach(item);
      final fetch = harness.fetcher.fetchesOf(item.key).single;

      fetch.receive(0, 400);
      expect(binding.transfer, const AssetTransfer.receiving(0, 400));

      fetch.receive(100, 400);
      expect(binding.transfer.fraction, 0.25);
    });

    test('an unknown total falls back to the byte size', () {
      final item = _video(1, thumbnail: false);
      final harness = PipelineHarness(known: [item], autoFetch: false);
      addTearDown(harness.dispose);
      final binding = harness.attach(item);

      harness.fetcher.fetchesOf(item.key).single.receive(1000, null);

      expect(binding.transfer, const AssetTransfer.receiving(1000, 4000));
    });

    test('a finished transfer is all of it until the content decodes', () {
      final item = sticker(1);
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDecode: false,
      );
      addTearDown(harness.dispose);
      final binding = harness.attach(item);

      return Future(() async {
        harness.fetcher.fetchesOf(item.key).single
          ..receive(10, 400)
          ..complete();
        await harness.settle();

        expect(binding.transfer, const AssetTransfer.receiving(400, 400));

        harness.decoder.decodes.single.complete();
        await harness.settle();

        expect(binding.readiness.stage, AssetStage.full);
        expect(binding.transfer, AssetTransfer.none);
      });
    });

    test('a cached item never leaves none', () {
      final item = sticker(1, thumbnail: true);
      final harness = PipelineHarness(known: [item], autoFetch: false);
      addTearDown(harness.dispose);
      final binding = harness.attach(item);
      final states = <AssetTransfer>[];
      binding.addListener(() => states.add(binding.transfer));

      return Future(() async {
        for (final fetch in harness.fetcher.fetchesOf(item.key)) {
          fetch.complete();
        }
        await harness.settle();

        expect(binding.readiness.stage, AssetStage.full);
        expect(states, everyElement(AssetTransfer.none));
      });
    });

    test('the thumbnail transfer is not the content transfer', () {
      final item = sticker(1, thumbnail: true);
      final harness = PipelineHarness(known: [item], autoFetch: false);
      addTearDown(harness.dispose);
      final binding = harness.attach(item);

      harness.fetcher
          .fetchesOf(item.key, FetchPart.thumbnail)
          .single
          .receive(10, 20);

      expect(binding.transfer, AssetTransfer.none);
    });
  });

  group('content known to be missing', () {
    test('waits from the attach, before any fetch reports', () {
      final item = sticker(1, thumbnail: true);
      final harness = PipelineHarness(known: [item], autoFetch: false);
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);

      final binding = harness.attach(item);

      expect(binding.transfer, const AssetTransfer.waiting());
    });

    test('a key the pipeline must resolve first waits from the attach', () {
      final item = sticker(1);
      final harness = PipelineHarness(
        served: [item],
        autoFetch: false,
        resolver: FakeMediaResolver([item]),
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);

      final binding = harness.attach(item);

      expect(binding.transfer, const AssetTransfer.waiting());
    });

    test('runs none, waiting, receiving, failed, receiving again, none', () {
      final item = _video(1, thumbnail: false);
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDecode: false,
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final binding = harness.attach(item);

      return Future(() async {
        expect(binding.transfer, const AssetTransfer.waiting(4000));
        harness.fetcher.fetchesOf(item.key).single
          ..receive(1000, 4000)
          ..fail(const FetchFailure.transient('offline'));
        await harness.settle();

        expect(binding.lastError, isA<FetchFailure>());
        expect(
          binding.transfer,
          const AssetTransfer.failed(AssetFailureKind.transient, 1000, 4000),
        );

        binding.download();
        // The retry starts where the bytes got to, not from 0.
        expect(binding.transfer, const AssetTransfer.receiving(1000, 4000));

        harness.fetcher.fetchesOf(item.key).last.complete();
        await harness.settle();
        harness.decoder.decodes.single.complete();
        await harness.settle();

        expect(binding.readiness.stage, AssetStage.full);
        expect(binding.transfer, AssetTransfer.none);
      });
    });

    test('a cancel stops the content fetch and keeps the thumbnail', () {
      final item = _video(1);
      final harness = PipelineHarness(known: [item], autoFetch: false);
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final binding = harness.attach(item);

      return Future(() async {
        harness.fetcher
            .fetchesOf(item.key, FetchPart.thumbnail)
            .single
            .complete();
        await harness.settle();
        final content =
            harness.fetcher.fetchesOf(item.key, FetchPart.content).single
              ..receive(100, 4000);

        binding.cancelDownload();
        await harness.settle();

        expect(content.isCancelled, isTrue);
        expect(binding.readiness.stage, AssetStage.placeholder);
        expect(binding.transfer, const AssetTransfer.awaitingUser(4000, 100));
        // The cancel holds across a detach and an attach.
        binding.detach();
        final again = harness.attach(item);
        await harness.settle();
        expect(again.transfer, const AssetTransfer.awaitingUser(4000, 100));
        expect(harness.fetcher.fetchesOf(item.key, FetchPart.content), [
          content,
        ]);
      });
    });
  });

  group('auto-download', () {
    test('manual fetches only the thumbnail and awaits the user', () {
      final item = _video(1);
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDownload: FakeAutoDownloadPolicy(),
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);

      final binding = harness.attach(item);

      return Future(() async {
        expect(binding.transfer, const AssetTransfer.awaitingUser(4000));
        expect(harness.fetcher.fetchesOf(item.key, FetchPart.content), isEmpty);
        harness.fetcher
            .fetchesOf(item.key, FetchPart.thumbnail)
            .single
            .complete();
        await harness.settle();

        expect(binding.readiness.stage, AssetStage.placeholder);
        expect(binding.lastError, isNull);
        expect(binding.transfer, const AssetTransfer.awaitingUser(4000));
      });
    });

    test('a tap downloads, the bytes grow and the content arrives', () {
      final item = _video(1, thumbnail: false);
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDownload: FakeAutoDownloadPolicy(),
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final binding = harness.attach(item);

      return Future(() async {
        await harness.settle();
        binding.download();

        final fetch = harness.fetcher.fetchesOf(item.key).single
          ..receive(2000, 4000);
        expect(binding.transfer.fraction, 0.5);
        fetch.complete();
        await harness.settle();

        expect(binding.readiness.stage, AssetStage.full);
        expect(binding.transfer, AssetTransfer.none);
      });
    });

    test('a tap asks for the whole content; the policy does not', () {
      final item = _video(1, thumbnail: false);
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDownload: FakeAutoDownloadPolicy(),
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final binding = harness.attach(item);

      return Future(() async {
        await harness.settle();
        expect(
          harness.fetcher.fetchesOf(item.key).every((f) => !f.request.whole),
          isTrue,
        );
        binding.download();

        expect(harness.fetcher.fetchesOf(item.key).last.request.whole, isTrue);
      });
    });

    test('bytes of streamed content that land after it was handed out '
        'reach the binding', () {
      final item = _video(1, thumbnail: false);
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDecode: false,
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final binding = harness.attach(item);

      return Future(() async {
        final fetch = harness.fetcher.fetchesOf(item.key).single
          ..receive(500, 4000)
          ..complete(const FetchedRanged(readerApi: 1, key: 'video-1'));
        await harness.settle();

        fetch.land(2000, 4000);
        expect(binding.transfer, const AssetTransfer.receiving(2000, 4000));
      });
    });

    test('bytes of streamed content that land after its spec is final '
        'complete the content: a spec waiting for it starts again', () {
      final item = _video(1, thumbnail: false);
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDecode: false,
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final binding = harness.attach(item);

      return Future(() async {
        final fetch = harness.fetcher.fetchesOf(item.key).single
          ..receive(500, 4000)
          ..complete(const FetchedRanged(readerApi: 1, key: 'video-1'));
        await harness.settle();
        // Another spec of the content waits for the download under way.
        final tile = harness.attach(item, firstFrameSpec);
        await harness.settle();
        harness.decoder.decodes.single.complete();
        await harness.settle();
        expect(binding.readiness.isFinal, isTrue);
        expect(tile.transfer, isA<AssetTransfer$AwaitingUser>());

        harness.fetcher.missing.remove(item.key);
        fetch.land(4000, 4000);
        await harness.settle();

        expect(tile.transfer, AssetTransfer.none);
        expect(harness.fetcher.fetchesOf(item.key), hasLength(2));
      });
    });

    test('a rest of streamed content that fails turns into failed, and '
        'download() tries again', () {
      final item = _video(1, thumbnail: false);
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDecode: false,
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final binding = harness.attach(item)..download();
      final rest = Completer<void>();

      return Future(() async {
        harness.fetcher.fetchesOf(item.key).last
          ..receive(500, 4000)
          ..complete(
            FetchedRanged(readerApi: 1, key: 'video-1', rest: rest.future),
          );
        await harness.settle();
        harness.decoder.decodes.single.complete();
        await harness.settle();
        expect(binding.readiness.isFinal, isTrue);

        rest.completeError(const FetchFailure.transient('offline'));
        await harness.settle();

        expect(
          binding.transfer,
          const AssetTransfer.failed(AssetFailureKind.transient, 500, 4000),
        );
        final fetches = harness.fetcher.fetchesOf(item.key).length;
        binding.download();
        expect(harness.fetcher.fetchesOf(item.key), hasLength(fetches + 1));
        expect(harness.fetcher.fetchesOf(item.key).last.request.whole, isTrue);
      });
    });

    test('prefix fetches a head that is not decoded, then awaits', () {
      final item = _video(1, thumbnail: false);
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDownload: FakeAutoDownloadPolicy(answer: AutoDownload.prefix),
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final binding = harness.attach(item);

      return Future(() async {
        final fetch = harness.fetcher.fetchesOf(item.key).single;
        expect(fetch.request.prefix, const Duration(seconds: 4));
        fetch
          ..receive(100, 4000)
          ..complete();
        await harness.settle();

        expect(harness.decoder.decodes, isEmpty);
        expect(binding.transfer, const AssetTransfer.awaitingUser(4000));
      });
    });

    test('cached content ignores the policy', () {
      final item = _video(1, thumbnail: false);
      final harness = PipelineHarness(
        known: [item],
        autoDownload: FakeAutoDownloadPolicy(),
      );
      addTearDown(harness.dispose);
      final binding = harness.attach(item);

      return Future(() async {
        await harness.settle();
        await harness.settle();

        expect(binding.readiness.stage, AssetStage.full);
      });
    });

    test('a policy change starts the waiting content within one turn', () {
      final item = _video(1, thumbnail: false);
      final policy = FakeAutoDownloadPolicy();
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDownload: policy,
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final binding = harness.attach(item);
      expect(harness.fetcher.fetchesOf(item.key), isEmpty);

      policy
        ..answer = AutoDownload.now
        ..changed();

      expect(harness.fetcher.fetchesOf(item.key), hasLength(1));
      expect(binding.transfer, const AssetTransfer.waiting(4000));
    });

    test(
      'the most permissive tag wins, and both surfaces see one transfer',
      () {
        final item = _video(1, thumbnail: false);
        final policy = FakeAutoDownloadPolicy()
          ..byContext[AutoDownloadContext.contacts] = AutoDownload.now;
        final harness = PipelineHarness(
          known: [item],
          autoFetch: false,
          autoDownload: policy,
        );
        addTearDown(harness.dispose);
        harness.fetcher.missing.add(item.key);
        final channel = harness.attach(
          item,
          spec,
          AutoDownloadContext.channels,
        );
        expect(harness.fetcher.fetchesOf(item.key), isEmpty);

        final contact = harness.attach(
          item,
          spec,
          AutoDownloadContext.contacts,
        );
        harness.fetcher.fetchesOf(item.key).single.receive(1000, 4000);

        expect(channel.transfer, const AssetTransfer.receiving(1000, 4000));
        expect(contact.transfer, channel.transfer);
      },
    );

    test('detaching the permissive binding mid-download goes on', () {
      final item = _video(1, thumbnail: false);
      final policy = FakeAutoDownloadPolicy()
        ..byContext[AutoDownloadContext.contacts] = AutoDownload.now;
      final harness = PipelineHarness(
        known: [item],
        autoFetch: false,
        autoDownload: policy,
      );
      addTearDown(harness.dispose);
      harness.fetcher.missing.add(item.key);
      final channel = harness.attach(item, spec, AutoDownloadContext.channels);
      harness.attach(item, spec, AutoDownloadContext.contacts).detach();
      final fetch = harness.fetcher.fetchesOf(item.key).single
        ..receive(1000, 4000);

      expect(fetch.isCancelled, isFalse);
      expect(channel.transfer, const AssetTransfer.receiving(1000, 4000));
    });
  });
}
