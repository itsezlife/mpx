import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/preparation/preparation_input.dart';
import 'package:mpx_core/src/preparation/prepared_media.dart';

/// The seam through which an item is made ready to upload: scaled, encoded or
/// compressed as its intent says, with a thumbnail.
///
/// Implemented by the capture package over its preparer; taken by whoever
/// uploads (a publish job, through its constructor), which then needs no
/// capture package and no camera or encoder. The host wires it in its
/// composition root; without it only items already prepared can be sent.
///
/// `MediaPreparationContract` (in `testing.dart`) holds every implementation
/// to this.
abstract interface class MediaPreparation {
  /// Starts preparing [input] as [intent] says and returns its handle. Items
  /// may queue behind others, by the implementation's limits; a queued item
  /// reports progress 0.
  PreparationHandle prepare(PreparationInput input, PreparationIntent intent);
}

/// One item being prepared: its progress, the prepared file, and a way to
/// stop it.
abstract interface class PreparationHandle {
  /// How far the item is, from 0 to 1, never going back; 1 once [result]
  /// completes.
  ValueListenable<double> get progress;

  /// The prepared item. Fails with a [PreparationException]:
  /// [PreparationCancelled] after [cancel], [PreparationFailed] otherwise.
  Future<PreparedMedia> get result;

  /// Stops the item and deletes what it wrote; [result] fails with
  /// [PreparationCancelled]. Idempotent; does nothing once [result] settled.
  Future<void> cancel();
}

/// Why a preparation did not produce its item.
@immutable
sealed class PreparationException implements Exception {
  const PreparationException();
}

/// The item was cancelled ([PreparationHandle.cancel]).
final class PreparationCancelled extends PreparationException {
  /// Creates the exception.
  const PreparationCancelled();

  @override
  bool operator ==(Object other) => other is PreparationCancelled;

  @override
  int get hashCode => (PreparationCancelled).hashCode;

  @override
  String toString() => 'PreparationCancelled';
}

/// The item could not be prepared. [code] is a short, stable reason with no
/// user content (no path, no file name), fit for a diagnostics field.
final class PreparationFailed extends PreparationException {
  /// Creates the exception.
  const PreparationFailed(this.code, {this.cause});

  /// A short, stable reason: `unreadable`, `unsupported`, `noSpace`, or the
  /// implementation's own.
  final String code;

  /// The underlying error, for logs; may carry user content.
  final Object? cause;

  @override
  bool operator ==(Object other) =>
      other is PreparationFailed && other.code == code;

  @override
  int get hashCode => Object.hash(PreparationFailed, code);

  @override
  String toString() => 'PreparationFailed($code)';
}
