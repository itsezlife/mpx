import 'dart:typed_data';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart' show BytesCacheKey;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../download/download_support.dart';
import '../upload/upload_support.dart';
import 'publish_support.dart';

/// The server identity the publisher answers for an item.
MediaKey serverKeyOf(String itemId) => MediaKey.remote('server-$itemId');

/// Publish jobs and tracked downloads on one facade, parts held until
/// [step] lets one through per upload, the publisher held until [publish].
final class TrackedHarness {
  TrackedHarness._(
    this.uploads,
    this.transport,
    this.publisher,
    this.store,
    this.fetcher,
  );

  static Future<TrackedHarness> open() async {
    final store = FakeStore();
    final fetcher = SteppedFetcher(store.store);
    // One part in flight: each step sends one part of each upload.
    final transport = fakeTransport(holdParts: true, bytesInFlight: part);
    final uploads = await UploadsHarness.open(
      lifecycle: ManualPlaybackLifecycleSource(
        initial: AppLifecycleState.resumed,
      ),
      transports: [transport],
      wait: (_) async {},
      files: sourceFiles,
      downloads: TransferDownloads(
        fetcher: fetcher,
        resolver: FakeMediaResolver(const [photoItem]),
        store: store.store,
      ),
    );
    addTearDown(() => uploads.transfers.dispose());
    final publisher = FakePublisher(hold: true);
    uploads.transfers.registerPublisher(publisherId, publisher);
    return TrackedHarness._(uploads, transport, publisher, store, fetcher);
  }

  final UploadsHarness uploads;
  final FakeUploadTransport transport;
  final FakePublisher publisher;
  final FakeStore store;

  Transfers get transfers => uploads.transfers;

  TrackedTransfers get tracked => transfers.tracked;

  final SteppedFetcher fetcher;

  /// Publishes items [ids], each a prepared file of [parts] parts whose
  /// local bytes are in the cache, as the picture a cell shows is.
  Future<PublishJob> publish(List<String> ids, {int parts = 3}) async {
    for (final id in ids) {
      await store.store.write(
        BytesCacheKey(keyOf(id).encoded),
        Uint8List.fromList(const [1, 2, 3]),
      );
    }
    final job = transfers.publish(
      requestOf([
        for (final id in ids)
          itemOf(id, PublishSource.prepared(preparedOf(parts * part))),
      ], tag: 'chat:1:m1'),
    );
    await pumpEventQueue();
    return job;
  }

  /// One step: a part of every upload acknowledged, a chunk of every
  /// download landed.
  Future<void> step() async {
    transport.held.forEach(transport.ack);
    await fetcher.step();
    await pumpEventQueue();
  }

  /// Answers the held publish call with each item's server key.
  Future<void> answer() async {
    publisher.answer(
      PublishOutcome.published(
        serverKeys: {
          for (final id in publisher.pending.single.items.keys)
            id: serverKeyOf(id),
        },
      ),
    );
    await pumpEventQueue();
    await uploads.settle();
    await pumpEventQueue();
  }

  AssetTransfer valueOf(MediaKey key) => tracked.watch(key).value;

  /// Every value [key]'s watchers hear from now on, the current one first.
  List<AssetTransfer> record(MediaKey key) {
    final watched = tracked.watch(key);
    final seen = [watched.value];
    void heard() {
      if (watched.value != seen.last) seen.add(watched.value);
    }

    watched.addListener(heard);
    addTearDown(() => watched.removeListener(heard));
    return seen;
  }

  /// Steps until [done], at most [max] times.
  Future<void> stepUntil(bool Function() done, {int max = 50}) async {
    for (var i = 0; i < max && !done(); i++) {
      await step();
    }
    expect(done(), isTrue, reason: 'did not get there');
  }
}
