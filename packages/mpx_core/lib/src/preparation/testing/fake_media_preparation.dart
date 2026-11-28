import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/preparation/media_preparation.dart';
import 'package:mpx_core/src/preparation/preparation_input.dart';
import 'package:mpx_core/src/preparation/prepared_media.dart';

/// A [MediaPreparation] a test scripts by hand: every [prepare] call gives a
/// [FakePreparationHandle] the test reports progress on, completes or fails.
///
/// Nothing moves by itself. [onPrepare], when set, runs for each new handle,
/// so a test can script every item the same way (complete at once, fail one
/// input).
final class FakeMediaPreparation implements MediaPreparation {
  /// Creates a fake; [onPrepare] runs for each new handle.
  FakeMediaPreparation({this.onPrepare});

  /// Runs for each handle [prepare] makes, right after it is made.
  void Function(FakePreparationHandle handle)? onPrepare;

  /// Every handle made, oldest first.
  final List<FakePreparationHandle> handles = [];

  /// The handle of the latest [prepare] call.
  FakePreparationHandle get last => handles.last;

  /// The handles that have neither completed nor failed.
  List<FakePreparationHandle> get pending => [
    for (final handle in handles)
      if (!handle.isDone) handle,
  ];

  @override
  FakePreparationHandle prepare(
    PreparationInput input,
    PreparationIntent intent,
  ) {
    final handle = FakePreparationHandle._(input, intent);
    handles.add(handle);
    onPrepare?.call(handle);
    return handle;
  }
}

/// One item of a [FakeMediaPreparation], driven by the test.
final class FakePreparationHandle implements PreparationHandle {
  FakePreparationHandle._(this.input, this.intent) {
    _result.future.ignore();
  }

  /// What was asked to be prepared.
  final PreparationInput input;

  /// How it was asked to be prepared.
  final PreparationIntent intent;

  final ValueNotifier<double> _progress = ValueNotifier(0);
  final Completer<PreparedMedia> _result = Completer();
  int _cancels = 0;

  @override
  ValueListenable<double> get progress => _progress;

  @override
  Future<PreparedMedia> get result => _result.future;

  /// Whether [result] has settled.
  bool get isDone => _result.isCompleted;

  /// How many times [cancel] was called.
  int get cancels => _cancels;

  /// Whether the item was cancelled before it settled.
  bool get isCancelled => _cancelled;
  bool _cancelled = false;

  /// Reports [fraction] (clamped to 0..1); a value below the last one is
  /// ignored, as progress never goes back. Ignored once settled.
  void report(double fraction) {
    if (isDone) return;
    final clamped = fraction.clamp(0.0, 1.0);
    if (clamped > _progress.value) _progress.value = clamped;
  }

  /// Completes the item with [media] (a photo file of 100 bytes beside the
  /// input when null); progress goes to 1. Ignored once settled.
  void complete([PreparedMedia? media]) {
    if (isDone) return;
    _progress.value = 1;
    _result.complete(
      media ??
          PreparedMedia(
            kind: switch (intent) {
              PreparationIntent$Photo() => PreparedKind.photo,
              PreparationIntent$Video() => PreparedKind.video,
              PreparationIntent$File() => PreparedKind.file,
            },
            path: '${input.path}.prepared',
            isOriginal: false,
            byteSize: 100,
            thumbnailPath: '${input.path}.thumbnail.jpg',
          ),
    );
  }

  /// Fails the item with [PreparationFailed] of [code]. Ignored once
  /// settled.
  void fail([String code = 'unreadable']) {
    if (isDone) return;
    _result.completeError(PreparationFailed(code));
  }

  @override
  Future<void> cancel() async {
    _cancels++;
    if (isDone) return;
    _cancelled = true;
    _result.completeError(const PreparationCancelled());
  }
}
