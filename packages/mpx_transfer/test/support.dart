import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

/// What a scripted run completes with: a stand-in for a remote reference or
/// a cached file.
@immutable
final class TestResult implements TransferResult {
  const TestResult(this.name);

  final String name;

  @override
  bool operator ==(Object other) => other is TestResult && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'TestResult($name)';
}

/// A harness in the foreground, disposed after the test.
TransfersHarness harness({
  ManualPlaybackLifecycleSource? lifecycle,
  TransferEnvelope? envelope,
  Duration? retention,
  bool online = true,
  DateTime Function()? now,
}) {
  final source =
      lifecycle ??
      ManualPlaybackLifecycleSource(initial: AppLifecycleState.resumed);
  final built = TransfersHarness(
    lifecycle: source,
    envelope: envelope,
    retention: retention ?? Transfers.defaultRetention,
    online: online,
    now: now,
  );
  addTearDown(() => built.transfers.dispose());
  return built;
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
