import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

/// A harness in the foreground, disposed after the test.
Future<TransfersHarness> harness({
  ManualPlaybackLifecycleSource? lifecycle,
  TransferEnvelope? envelope,
  Duration? retention,
  bool online = true,
  DateTime Function()? now,
  Duration? progressInterval,
  JournalStore Function()? store,
  TransferDownloads? downloads,
}) async {
  final source =
      lifecycle ??
      ManualPlaybackLifecycleSource(initial: AppLifecycleState.resumed);
  final built = await TransfersHarness.open(
    lifecycle: source,
    envelope: envelope,
    retention: retention ?? Transfers.defaultRetention,
    progressInterval: progressInterval ?? Transfers.defaultProgressInterval,
    online: online,
    now: now,
    store: store,
    downloads: downloads,
  );
  addTearDown(() => built.transfers.dispose());
  return built;
}

/// [harness] inside a fake-async zone: opened by flushing its microtasks.
TransfersHarness harnessIn(
  FakeAsync async, {
  Duration? retention,
  DateTime Function()? now,
  Duration? progressInterval,
  JournalStore Function()? store,
}) {
  TransfersHarness? built;
  unawaited(
    harness(
      retention: retention,
      now: now,
      progressInterval: progressInterval,
      store: store,
    ).then((opened) => built = opened),
  );
  async.flushMicrotasks();
  return built!;
}

/// The jobs [transfers] holds now that [filter] passes.
Future<List<TransferJob>> jobsOf(
  Transfers transfers, [
  TransferFilter filter = const TransferFilter(),
]) => transfers.watch(filter).first;

/// The state of job [id] now, or null when there is no such job.
Future<TransferState?> stateOf(Transfers transfers, TransferId id) async {
  for (final job in await jobsOf(transfers)) {
    if (job.id == id) return job.state;
  }
  return null;
}

const MediaKey photo = MediaKey.remote('photo-1');
const MediaKey video = MediaKey.remote('video-2');
