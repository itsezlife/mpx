import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/testing.dart';

/// 64 KiB, the fake transport's default part size.
const int part = FakeUploadTransport.defaultPartSize;

/// The source files of the tests' uploads, which no test writes to disk.
final FakeUploadSourceFiles sourceFiles = FakeUploadSourceFiles();

int _sources = 0;

/// A finished source of [size] bytes at a path of its own, put in
/// [sourceFiles]; the fake transport never reads it.
UploadSource sourceOf(int size) {
  final path = '/uploads/source-${_sources++}.bin';
  sourceFiles.put(path, size: size);
  return UploadSource.finished(path, size: size);
}

/// A fake transport that splits every file into parts of [partSize] and
/// keeps up to [bytesInFlight] outstanding.
FakeUploadTransport fakeTransport({
  int partSize = part,
  int bytesInFlight = 4 * part,
  UploadResume resume = const UploadResume.unlimited(),
  bool holdParts = false,
  String id = 'fake',
}) => FakeUploadTransport(
  id: id,
  holdParts: holdParts,
  capabilities: UploadCapabilities(
    partSize: (_) => partSize,
    bytesInFlight: bytesInFlight,
    resume: resume,
    reuse: const UploadReuse.lifetime(Duration(hours: 24)),
  ),
);

/// An uploads harness in the foreground over [transports], whose retry
/// waits return at once and are recorded in [waits], reading source files
/// from [files] ([sourceFiles] by default); disposed after the test.
Future<UploadsHarness> uploads(
  List<UploadTransport> transports, {
  List<Duration>? waits,
  DateTime Function()? now,
  Duration? progressInterval,
  int? laneSplit,
  JournalStore Function()? store,
  UploadSourceFiles? files,
}) async {
  final built = await UploadsHarness.open(
    lifecycle: ManualPlaybackLifecycleSource(
      initial: AppLifecycleState.resumed,
    ),
    transports: transports,
    store: store,
    now: now,
    progressInterval: progressInterval ?? Transfers.defaultProgressInterval,
    laneSplit: laneSplit ?? UploadLane.defaultSplit,
    wait: (delay) async => waits?.add(delay),
    files: files ?? sourceFiles,
  );
  addTearDown(() => built.transfers.dispose());
  return built;
}

/// The state of job [id] now, or null when there is no such job.
Future<TransferState?> stateOf(Transfers transfers, TransferId id) async {
  for (final job in await transfers.watch().first) {
    if (job.id == id) return job.state;
  }
  return null;
}
