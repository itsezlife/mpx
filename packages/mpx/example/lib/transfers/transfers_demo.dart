import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/transfers/dev_server.dart';
import 'package:mpx_example/transfers/environment_specific/transfers_host.dart'
    as environment_specific;
import 'package:mpx_example/transfers/transfer_settings.dart';
import 'package:mpx_example/transfers/transfers_root.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

/// One file the user picked to send: where it is and what the system says
/// of it.
@immutable
final class DemoPick {
  const DemoPick({
    required this.path,
    required this.size,
    this.mimeType,
    this.name,
    this.modified,
  });

  /// Picks images and videos through the system's file dialog. A picked
  /// file the platform hands as a blob (the web) is left out: the engine's
  /// publish jobs read files.
  static Future<List<DemoPick>> fromFileDialog() async {
    final intake = await PlatformIntake.fileIntake();
    final files = await intake.pickFiles(filter: IntakeFilter.imagesAndVideos);
    return [
      for (final file in files)
        if (file.source case IntakeSource$Path(:final path))
          DemoPick(
            path: path,
            size: file.size,
            mimeType: file.mimeType,
            name: file.name,
            modified: file.modified,
          ),
    ];
  }

  final String path;
  final int size;
  final String? mimeType;
  final String? name;
  final DateTime? modified;

  /// The intent the item is prepared by: its kind.
  PreparationIntent get intent => switch (mimeType) {
    final type? when type.startsWith('video/') =>
      const PreparationIntent.video(),
    final type? when type.startsWith('image/') =>
      const PreparationIntent.photo(),
    _ => const PreparationIntent.file(),
  };

  MediaKind get kind => switch (mimeType) {
    final type? when type.startsWith('video/') => MediaKind.video,
    final type? when type.startsWith('image/') => MediaKind.still,
    _ => MediaKind.unknown,
  };

  /// What the reuse table knows the content by: a digest of the picked
  /// file's name, size and modification time, so the same item picked twice
  /// (a new temporary copy each time) is the same content. A digest, so no
  /// file name is kept.
  String get fingerprint => sha256
      .convert(utf8.encode('$name|$size|${modified?.toIso8601String()}'))
      .toString()
      .substring(0, 32);
}

/// The demo's headless side: sends picks as publish jobs to the server's
/// publisher through the chosen transport, forwards an item the server
/// already holds as a remote item, lists the server's files, and runs the
/// debug panel's actions.
///
/// [keepLocal] puts a picked file's bytes in the cache under its local key,
/// so its cell shows the picture before any upload; [know] tells the
/// pipeline what each key is.
final class TransfersDemo {
  TransfersDemo({
    required this.root,
    required this.keepLocal,
    required this.know,
    this.kill = environment_specific.$killProcess,
  });

  final TransfersRoot root;

  /// Puts the bytes of [pick] in the cache under [key].
  final Future<void> Function(MediaKey$Local key, DemoPick pick) keepLocal;

  /// Tells the pipeline what [descriptor]'s key is.
  final void Function(MediaDescriptor descriptor) know;

  /// Ends the process as a kill would (a reload on the web).
  final void Function() kill;

  Transfers get transfers => root.transfers;
  DevServer get server => root.server;
  TransferSettings get settings => root.settings;

  /// The server's files, as last listed; [refreshFiles] lists them again.
  final ValueNotifier<List<DevServerFile>> files = ValueNotifier(const []);

  /// Why the last listing failed, or null.
  final ValueNotifier<String?> filesError = ValueNotifier(null);

  final math.Random _random = math.Random.secure();

  // A fresh local key: a random (version 4) UUID.
  MediaKey$Local _mintKey() {
    final bytes = List.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = [
      for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
    ].join();
    return MediaKey$Local(
      '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}',
    );
  }

  // The tag of a new job: ids only (the demo's prefix and a random id).
  String _nextTag() => 'demo:${_mintKey().uuid.substring(0, 8)}';

  /// Sends [picks] as one publish job to the server's publisher through
  /// [transport] ([TransferSettings.transport] unless given). With
  /// [prepare] each item is prepared by its kind (stills scaled, videos
  /// compressed); without, it uploads as picked.
  Future<PublishJob> send(
    List<DemoPick> picks, {
    bool prepare = true,
    DemoTransport? transport,
  }) async {
    final items = <PublishItem>[];
    for (final pick in picks) {
      final key = _mintKey();
      know(
        MediaDescriptor(
          key: key,
          kind: pick.kind,
          animated: pick.kind == MediaKind.video,
          byteSize: pick.size,
        ),
      );
      try {
        await keepLocal(key, pick);
      } on Object catch (error) {
        // The cell shows no picture; the upload does not depend on it.
        debugPrint('The local picture was not kept ($error).');
      }
      items.add(
        PublishItem(
          itemId: key.uuid,
          key: key,
          fingerprint: pick.fingerprint,
          source: prepare
              ? PublishSource.prepare(
                  PreparationInput(
                    pick.path,
                    mimeType: pick.mimeType,
                    byteSize: pick.size,
                  ),
                  pick.intent,
                )
              : PublishSource.prepared(
                  PreparedMedia(
                    kind: switch (pick.kind) {
                      MediaKind.video => PreparedKind.video,
                      MediaKind.still => PreparedKind.photo,
                      _ => PreparedKind.file,
                    },
                    path: pick.path,
                    isOriginal: true,
                    byteSize: pick.size,
                    mimeType: pick.mimeType,
                  ),
                ),
        ),
      );
    }
    return transfers.publish(
      PublishRequest(
        tag: _nextTag(),
        items: items,
        payload: utf8.encode(jsonEncode({'items': picks.length})),
        publisher: DevServerPublisher.id,
        transport: (transport ?? settings.transport).id,
      ),
    );
  }

  /// Sends [key], a content the server already holds, again: as a remote
  /// item, with nothing to upload.
  PublishJob forward(MediaKey key) => transfers.publish(
    PublishRequest(
      tag: _nextTag(),
      items: [
        PublishItem(
          itemId: _mintKey().uuid,
          key: key,
          source: const PublishSource.remote(),
        ),
      ],
      payload: utf8.encode(jsonEncode({'forwarded': 1})),
      publisher: DevServerPublisher.id,
      transport: settings.transport.id,
    ),
  );

  /// The server key of an item [snapshot] uploaded: the server's file
  /// holding it, or null before its upload completed.
  static MediaKey? serverKeyOf(PublishItemSnapshot snapshot) =>
      switch (snapshot.state) {
        PublishItemState$Uploaded(:final file?) => DevServer.keyOf(file.id),
        _ => null,
      };

  /// Lists the server's files again, telling the pipeline what each is.
  Future<void> refreshFiles() async {
    try {
      final listed = await server.files();
      for (final file in listed) {
        know(file.descriptor);
      }
      files.value = listed;
      filesError.value = null;
    } on Object catch (error) {
      filesError.value = '$error';
    }
  }

  /// A download of [key] the user asked for: it resumes by itself after a
  /// restart.
  TransferId download(MediaKey key) =>
      transfers.download(key, origin: TransferOrigin.user);

  // --- The debug panel's actions ---------------------------------------------

  Timer? _kill;

  /// Whether a kill is counting down.
  bool get killPending => _kill != null;

  /// Kills the process after [delay] (3 s by default), so the app can be
  /// backgrounded first or the kill land mid-transfer.
  void killIn([Duration delay = const Duration(seconds: 3)]) {
    _kill?.cancel();
    _kill = Timer(delay, () {
      _kill = null;
      kill();
    });
  }

  /// Stops a kill counting down.
  void cancelKill() {
    _kill?.cancel();
    _kill = null;
  }

  /// Cuts the app's network, or gives it back: the requests fail and the
  /// engine is told it is offline.
  set networkCut(bool cut) => root.cut.value = cut;
  bool get networkCut => root.cut.value;

  /// Acts out a system end of the OS envelope (debug builds): its jobs
  /// pause `systemInterrupted` until the app is next in the foreground.
  /// Answers how many jobs paused.
  int simulateSystemInterruption() =>
      transfers.debugSimulateSystemInterruption();

  void dispose() {
    _kill?.cancel();
    files.dispose();
    filesError.dispose();
  }
}
