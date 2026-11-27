import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart' as support;

/// The content the tests download: 400 bytes, landed 100 per step.
const MediaDescriptor photoItem = MediaDescriptor(
  key: support.photo,
  kind: MediaKind.still,
  byteSize: 400,
  thumbnail: MediaThumbnailRef('thumb-photo'),
);

/// A second content, for tests of two keys.
const MediaDescriptor videoItem = MediaDescriptor(
  key: support.video,
  kind: MediaKind.still,
  byteSize: 300,
);

/// A bytes store in memory whose payloads have file paths, as a disk store's
/// do.
final class FakeStore {
  /// The payloads, by key value; a test can see what eviction freed.
  final FakeBytesBlobStore blobs = FakeBytesBlobStore();

  /// The store.
  late final IBytesStore store = IndexedBytesCache(
    index: FakeBytesIndex(),
    blobs: blobs,
  );
}

/// A [ContentFetcher] that plays the bytes cache and its network: a fetch of
/// content not in [store] is a transfer that lands [chunk] bytes per [step],
/// going on from what earlier fetches landed (the cache's ranged data), and
/// writes the whole content into [store]. Content in [store], and every
/// thumbnail, is served at once.
final class SteppedFetcher implements ContentFetcher {
  /// A fetcher over [store], keying content as `MediaKey.encoded`.
  SteppedFetcher(this.store, {this.chunk = 100});

  /// Where whole content lands.
  final IBytesStore store;

  /// Bytes per [step].
  final int chunk;

  /// Bytes landed per key: what a fetch goes on from.
  final Map<MediaKey, int> landed = {};

  /// Every request, oldest first.
  final List<FetchRequest> requests = [];

  /// The content requests, oldest first.
  List<FetchRequest> get contentRequests => [
    for (final request in requests)
      if (request.part == FetchPart.content) request,
  ];

  /// Whether the network is there; while not, transfers fail transiently.
  bool online = true;

  /// Whether new transfers wait in the queue, reporting nothing, until the
  /// next [step]: a request no slot has taken yet.
  bool queue = false;

  final List<_Transfer> _transfers = [];

  /// How many transfers are under way.
  int get transfers => _transfers.length;

  @override
  Future<FetchedContent> fetch(FetchRequest request) async {
    requests.add(request);
    final key = request.descriptor.key;
    if (request.part == FetchPart.thumbnail) {
      return FetchedContent.bytes(Uint8List.fromList(const [1, 2, 3]));
    }
    final cached = await store.read(BytesCacheKey(key.encoded));
    if (cached != null) return FetchedContent.bytes(cached);
    final transfer = _Transfer(request);
    if (!online) {
      throw const FetchFailure.transient('offline');
    }
    _transfers.add(transfer);
    request.cancellation.onCancel(() {
      _transfers.remove(transfer);
      if (!transfer.done.isCompleted) {
        transfer.done.completeError(const FetchFailure.transient('cancelled'));
      }
    });
    if (queue) {
      transfer.queued = true;
    } else {
      request.onProgress(landed[key] ?? 0, request.descriptor.byteSize);
    }
    return transfer.done.future;
  }

  /// Lands one chunk of every transfer under way; a transfer that is whole
  /// writes its content and completes.
  Future<void> step() async {
    for (final transfer in [..._transfers]) {
      final request = transfer.request;
      final key = request.descriptor.key;
      final size = request.descriptor.byteSize!;
      if (transfer.queued) {
        transfer.queued = false;
        request.onProgress(landed[key] ?? 0, size);
        continue;
      }
      final now = landed[key] = ((landed[key] ?? 0) + chunk).clamp(0, size);
      request.onProgress(now, size);
      if (now < size) continue;
      _transfers.remove(transfer);
      final bytes = Uint8List(size);
      await store.write(BytesCacheKey(key.encoded), bytes);
      transfer.done.complete(FetchedContent.bytes(bytes));
    }
  }

  /// Fails every transfer under way, as a dropped network does.
  void failAll() {
    for (final transfer in [..._transfers]) {
      _transfers.remove(transfer);
      transfer.done.completeError(const FetchFailure.transient('offline'));
    }
  }

  @override
  bool needsDownload(MediaKey key) =>
      !store.contains(BytesCacheKey(key.encoded));
}

final class _Transfer {
  _Transfer(this.request);

  final FetchRequest request;
  final Completer<FetchedContent> done = Completer();
  bool queued = false;
}

/// A harness whose download jobs fetch through [fetcher] into [store].
final class DownloadsHarness {
  DownloadsHarness._(this.store, this.fetcher, this.harness);

  /// Opens one in the foreground, disposed after the test.
  static Future<DownloadsHarness> open({
    ManualPlaybackLifecycleSource? lifecycle,
    TransferEnvelope? envelope,
  }) async {
    final store = FakeStore();
    final fetcher = SteppedFetcher(store.store);
    final built = await support.harness(
      lifecycle: lifecycle,
      envelope: envelope,
      downloads: TransferDownloads(
        fetcher: fetcher,
        resolver: FakeMediaResolver(const [photoItem, videoItem]),
        store: store.store,
      ),
    );
    return DownloadsHarness._(store, fetcher, built);
  }

  /// The store the content lands in.
  final FakeStore store;

  /// The network.
  final SteppedFetcher fetcher;

  /// The engine harness.
  final TransfersHarness harness;

  /// The facade now.
  Transfers get transfers => harness.transfers;

  /// The seam now.
  TrackedTransfers get tracked => transfers.tracked;

  /// Lands one chunk everywhere and lets the engine take it in.
  Future<void> step() async {
    await fetcher.step();
    await pumpEventQueue();
  }

  /// Lets resolves and fetches start.
  Future<void> settle() => pumpEventQueue();

  /// What [tracked] shows for [key] now.
  AssetTransfer valueOf(MediaKey key) => tracked.watch(key).value;

  /// The job of [key] now, or null.
  Future<TransferJob?> jobOf(MediaKey key) async {
    final id = TransferId.forDownload(key.encoded);
    for (final job in await support.jobsOf(transfers)) {
      if (job.id == id) return job;
    }
    return null;
  }
}
