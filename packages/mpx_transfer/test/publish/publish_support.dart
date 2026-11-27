import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';

/// What `FakeMediaPreparation` answers: a prepared file of 100 bytes.
const int preparedSize = 100;

/// The size of the thumbnail beside each prepared file.
const int thumbnailSize = 20;

/// The publisher id the tests register.
const String publisherId = 'test.publish';

int _inputs = 0;

/// A source file of [size] bytes for preparation, with the prepared file
/// and thumbnail `FakeMediaPreparation` names put beside it.
PreparationInput inputOf(int size) {
  final path = '/inputs/input-${_inputs++}.bin';
  sourceFiles
    ..put(path, size: size)
    ..put('$path.prepared', size: preparedSize)
    ..put('$path.thumbnail.jpg', size: thumbnailSize);
  return PreparationInput(path, byteSize: size);
}

/// An already prepared file of [size] bytes, of [kind], in [sourceFiles].
PreparedMedia preparedOf(
  int size, {
  PreparedKind kind = PreparedKind.file,
  bool thumbnail = false,
}) {
  final path = '/prepared/file-${_inputs++}.bin';
  sourceFiles.put(path, size: size);
  if (thumbnail) sourceFiles.put('$path.jpg', size: thumbnailSize);
  return PreparedMedia(
    kind: kind,
    path: path,
    isOriginal: true,
    byteSize: size,
    thumbnailPath: thumbnail ? '$path.jpg' : null,
  );
}

final Map<String, MediaKey> _keys = {};

/// The local key of item [id]: one per id, the same on every call.
MediaKey keyOf(String id) => _keys.putIfAbsent(
  id,
  () => MediaKey.local(
    '00000000-0000-4000-8000-${_keys.length.toRadixString(16).padLeft(12, '0')}',
  ),
);

/// An item [id] whose bytes come from [source].
PublishItem itemOf(String id, PublishSource source, {String? fingerprint}) =>
    PublishItem(
      itemId: id,
      key: keyOf(id),
      source: source,
      fingerprint: fingerprint,
    );

/// A request to publish [items] through [publisherId].
PublishRequest requestOf(
  List<PublishItem> items, {
  String publisher = publisherId,
  String? idempotencyKey,
  String? tag,
  List<int> payload = const [1, 2, 3],
}) => PublishRequest(
  items: items,
  payload: Uint8List.fromList(payload),
  publisher: publisher,
  idempotencyKey: idempotencyKey,
  tag: tag,
);

/// A harness in the foreground running publish jobs over [transports],
/// preparing through [preparation]; disposed after the test.
Future<UploadsHarness> publishing(
  List<UploadTransport> transports, {
  MediaPreparation? preparation,
  DateTime Function()? now,
  Duration? progressInterval,
  JournalStore Function()? store,
  PublishProgressWeights progressWeights = PublishProgressWeights.standard,
  ManualPlaybackLifecycleSource? lifecycle,
  TransferEnvelope? envelope,
  TransferEnvelopeConfig? envelopeConfig,
}) async {
  final built = await UploadsHarness.open(
    store: store,
    lifecycle:
        lifecycle ??
        ManualPlaybackLifecycleSource(initial: AppLifecycleState.resumed),
    envelope: envelope,
    envelopeConfig: envelopeConfig,
    transports: transports,
    now: now,
    progressInterval: progressInterval ?? Transfers.defaultProgressInterval,
    wait: (_) async {},
    files: sourceFiles,
    preparation: preparation,
    progressWeights: progressWeights,
  );
  addTearDown(() => built.transfers.dispose());
  return built;
}

/// Every distinct state [job] went through while [body] ran.
Future<List<String>> statesDuring(
  PublishJob job,
  Future<void> Function() body,
) async {
  final names = <String>[];
  final subscription = job.watch().listen((snapshot) {
    if (names.lastOrNull != snapshot.state.name) {
      names.add(snapshot.state.name);
    }
  });
  await pumpEventQueue();
  await body();
  await pumpEventQueue();
  await subscription.cancel();
  return names;
}
