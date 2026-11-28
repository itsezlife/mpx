import 'package:flutter/foundation.dart';

/// Why an item of a save batch was not saved.
enum SaveFailure {
  /// The user or a policy refused the access the save needs.
  accessDenied,

  /// The destination has no room for it.
  noSpace,

  /// The destination does not take this content: a non-media file sent to
  /// the gallery, or a format the platform's gallery refuses.
  unsupportedFormat,

  /// The save cannot happen here: no adapter on this platform, the build
  /// leaves the code out, the source is gone, or the platform failed in a
  /// way none of the other reasons names.
  unavailable,
}

/// How one item of a save batch ended.
@immutable
sealed class SaveResult {
  const SaveResult();

  /// Saved; [platformRef] names the saved item where the platform tells
  /// (an Android content URI, a Photos asset's local identifier, a desktop
  /// file path) and is null on the web, where the browser confirms nothing.
  /// [renamed] is true when the platform gave it another name because one
  /// was taken.
  const factory SaveResult.saved(String? platformRef, {bool renamed}) =
      SaveResult$Saved;

  /// Cancelled before it was saved.
  const factory SaveResult.cancelled() = SaveResult$Cancelled;

  /// Not saved, for [reason]. [code] is the platform's own short error code,
  /// with no user content, for diagnostics.
  const factory SaveResult.failed(SaveFailure reason, {String? code}) =
      SaveResult$Failed;

  /// Whether the item was saved.
  bool get isSaved => this is SaveResult$Saved;
}

/// [SaveResult.saved].
final class SaveResult$Saved extends SaveResult {
  /// Saved as [platformRef].
  const SaveResult$Saved(this.platformRef, {this.renamed = false});

  /// The platform's name for the saved item; null on the web.
  final String? platformRef;

  /// Whether the platform renamed it on a collision.
  final bool renamed;

  @override
  bool operator ==(Object other) =>
      other is SaveResult$Saved &&
      other.platformRef == platformRef &&
      other.renamed == renamed;

  @override
  int get hashCode => Object.hash(SaveResult$Saved, platformRef, renamed);

  // The ref can be a path: kept out of strings logs may hold.
  @override
  String toString() =>
      'SaveResult.saved(ref: ${platformRef != null}, renamed: $renamed)';
}

/// [SaveResult.cancelled].
final class SaveResult$Cancelled extends SaveResult {
  /// Cancelled.
  const SaveResult$Cancelled();

  @override
  bool operator ==(Object other) => other is SaveResult$Cancelled;

  @override
  int get hashCode => (SaveResult$Cancelled).hashCode;

  @override
  String toString() => 'SaveResult.cancelled()';
}

/// [SaveResult.failed].
final class SaveResult$Failed extends SaveResult {
  /// Failed for [reason].
  const SaveResult$Failed(this.reason, {this.code});

  /// Why.
  final SaveFailure reason;

  /// The platform's short error code, when it gave one.
  final String? code;

  @override
  bool operator ==(Object other) =>
      other is SaveResult$Failed &&
      other.reason == reason &&
      other.code == code;

  @override
  int get hashCode => Object.hash(SaveResult$Failed, reason, code);

  @override
  String toString() =>
      'SaveResult.failed(${reason.name}'
      '${code == null ? '' : ', code: $code'})';
}
