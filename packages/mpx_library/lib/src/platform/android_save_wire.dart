/// The method-channel wire of the Android save adapter: what the Dart side
/// asks the plugin's native saver to begin ([AndroidSaveStart],
/// [AndroidSaveStartCodec]) and what each copy step answers
/// ([AndroidSaveStep], [AndroidSaveStepCodec]).
///
/// ## Methods
///
/// | Method | Arguments | Answer |
/// | --- | --- | --- |
/// | `saveBegin` | an [AndroidSaveStart] map | the write's id (an int), or null when the user dismissed the save dialog |
/// | `saveStep` | `write`: the id | an [AndroidSaveStep] map: up to a few MiB more copied, or the save done |
/// | `saveAbort` | `write`: the id | null; the pending row or file is removed (unknown ids are ignored) |
///
/// A failure is a `PlatformException` whose code is the platform's short
/// error code (`ENOSPC`, `mimeRejected`, `security`, `sourceMissing`,
/// `insertFailed`, `nameTaken`, `noActivity`, `failed`); a failed step has
/// already removed its pending row.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mpx_library/src/save/save_item.dart';

/// One item the native saver is asked to begin writing.
@immutable
final class AndroidSaveStart {
  /// The start of an item to [destination].
  const AndroidSaveStart({
    required this.destination,
    required this.name,
    required this.mimeType,
    required this.kind,
    this.folder,
    this.createdAt,
    this.path,
    this.bytes,
    this.move = false,
  }) : assert(
         (path == null) != (bytes == null),
         'An item has a file or bytes, not both and not neither.',
       );

  /// `gallery`, `downloads` or `ask`.
  final String destination;

  /// The gallery album (the `Pictures/<album>` sub-folder) or the downloads
  /// sub-folder; null for none.
  final String? folder;

  /// The file name to save as.
  final String name;

  /// The content's MIME type.
  final String mimeType;

  /// What to file it as, after the shared routing.
  final SaveItemKind kind;

  /// Written as `DATE_TAKEN` (the file's modification time below API 29).
  final DateTime? createdAt;

  /// The source file; null for [bytes].
  final String? path;

  /// The content when there is no file.
  final Uint8List? bytes;

  /// Whether the source may be consumed once saved.
  final bool move;

  @override
  bool operator ==(Object other) =>
      other is AndroidSaveStart &&
      other.destination == destination &&
      other.folder == folder &&
      other.name == name &&
      other.mimeType == mimeType &&
      other.kind == kind &&
      other.createdAt == createdAt &&
      other.path == path &&
      listEquals(other.bytes, bytes) &&
      other.move == move;

  @override
  int get hashCode => Object.hash(
    destination,
    folder,
    name,
    mimeType,
    kind,
    createdAt,
    path,
    bytes?.length,
    move,
  );

  // Name, folder and path are user content.
  @override
  String toString() => 'AndroidSaveStart($destination, ${kind.name})';
}

/// What one `saveStep` answers.
@immutable
sealed class AndroidSaveStep {
  const AndroidSaveStep(this.written, this.total);

  /// [written] of [total] bytes copied so far; more steps follow.
  const factory AndroidSaveStep.copying(int written, int? total) =
      AndroidSaveStep$Copying;

  /// Every byte copied ([written]) and the save published as [ref].
  const factory AndroidSaveStep.done(
    int written, {
    required String ref,
    required bool renamed,
  }) = AndroidSaveStep$Done;

  /// The bytes copied so far.
  final int written;

  /// The source's length, when known.
  final int? total;
}

/// [AndroidSaveStep.copying].
final class AndroidSaveStep$Copying extends AndroidSaveStep {
  /// Copying.
  const AndroidSaveStep$Copying(super.written, super.total);

  @override
  bool operator ==(Object other) =>
      other is AndroidSaveStep$Copying &&
      other.written == written &&
      other.total == total;

  @override
  int get hashCode => Object.hash(AndroidSaveStep$Copying, written, total);

  @override
  String toString() => 'AndroidSaveStep.copying($written, $total)';
}

/// [AndroidSaveStep.done].
final class AndroidSaveStep$Done extends AndroidSaveStep {
  /// Done.
  const AndroidSaveStep$Done(
    int written, {
    required this.ref,
    required this.renamed,
  }) : super(written, written);

  /// The saved item's content URI (a file URI below API 29 when the media
  /// scanner gave none).
  final String ref;

  /// Whether the platform gave it another name because one was taken.
  final bool renamed;

  @override
  bool operator ==(Object other) =>
      other is AndroidSaveStep$Done &&
      other.written == written &&
      other.ref == ref &&
      other.renamed == renamed;

  @override
  int get hashCode => Object.hash(AndroidSaveStep$Done, written, ref, renamed);

  // The ref is a platform ref: kept out of strings logs may hold.
  @override
  String toString() => 'AndroidSaveStep.done($written, renamed: $renamed)';
}

/// [AndroidSaveStart] ↔ the `saveBegin` arguments.
///
/// ## Format
///
/// | Key | Value |
/// | --- | --- |
/// | `destination` | `gallery`, `downloads` or `ask` |
/// | `folder` | optional string: the album or sub-folder |
/// | `name` | string |
/// | `mime` | string |
/// | `kind` | `photo`, `video`, `animation` or `file` |
/// | `createdAtMs` | optional int: milliseconds since the epoch, UTC |
/// | `path` | string, or absent with `bytes` |
/// | `bytes` | byte list, or absent with `path` |
/// | `move` | bool |
///
/// Decoding is strict: a missing or mistyped field throws a
/// [FormatException] whose message names it.
final class AndroidSaveStartCodec
    extends Codec<AndroidSaveStart, Map<Object?, Object?>> {
  /// The codec.
  const AndroidSaveStartCodec();

  @override
  Converter<AndroidSaveStart, Map<Object?, Object?>> get encoder =>
      const _StartEncoder();

  @override
  Converter<Map<Object?, Object?>, AndroidSaveStart> get decoder =>
      const _StartDecoder();
}

/// [AndroidSaveStep] ↔ the `saveStep` answer.
///
/// ## Format
///
/// | Key | Value |
/// | --- | --- |
/// | `written` | int: bytes copied so far |
/// | `total` | optional int: the source's length |
/// | `done` | optional bool, true once the save is published |
/// | `ref` | string, with `done`: the content URI |
/// | `renamed` | bool, with `done`: renamed on a name collision |
///
/// Decoding is strict: a missing or mistyped field throws a
/// [FormatException] whose message names it.
final class AndroidSaveStepCodec
    extends Codec<AndroidSaveStep, Map<Object?, Object?>> {
  /// The codec.
  const AndroidSaveStepCodec();

  @override
  Converter<AndroidSaveStep, Map<Object?, Object?>> get encoder =>
      const _StepEncoder();

  @override
  Converter<Map<Object?, Object?>, AndroidSaveStep> get decoder =>
      const _StepDecoder();
}

abstract final class _Key {
  static const String destination = 'destination';
  static const String folder = 'folder';
  static const String name = 'name';
  static const String mime = 'mime';
  static const String kind = 'kind';
  static const String createdAtMs = 'createdAtMs';
  static const String path = 'path';
  static const String bytes = 'bytes';
  static const String move = 'move';
  static const String written = 'written';
  static const String total = 'total';
  static const String done = 'done';
  static const String ref = 'ref';
  static const String renamed = 'renamed';
}

final class _StartEncoder
    extends Converter<AndroidSaveStart, Map<Object?, Object?>> {
  const _StartEncoder();

  @override
  Map<Object?, Object?> convert(AndroidSaveStart input) => {
    _Key.destination: input.destination,
    _Key.folder: ?input.folder,
    _Key.name: input.name,
    _Key.mime: input.mimeType,
    _Key.kind: input.kind.name,
    _Key.createdAtMs: ?input.createdAt?.millisecondsSinceEpoch,
    _Key.path: ?input.path,
    _Key.bytes: ?input.bytes,
    _Key.move: input.move,
  };
}

final class _StartDecoder
    extends Converter<Map<Object?, Object?>, AndroidSaveStart> {
  const _StartDecoder();

  @override
  AndroidSaveStart convert(Map<Object?, Object?> input) {
    final kind = SaveItemKind.values
        .asNameMap()[_Read.string(input, _Key.kind)];
    if (kind == null) throw FormatException(_Key.kind, input);
    final createdAtMs = _Read.optional<int>(input, _Key.createdAtMs);
    final path = _Read.optional<String>(input, _Key.path);
    final bytes = _Read.optional<Uint8List>(input, _Key.bytes);
    if ((path == null) == (bytes == null)) {
      throw FormatException(_Key.path, input);
    }
    return AndroidSaveStart(
      destination: _Read.string(input, _Key.destination),
      folder: _Read.optional<String>(input, _Key.folder),
      name: _Read.string(input, _Key.name),
      mimeType: _Read.string(input, _Key.mime),
      kind: kind,
      createdAt: createdAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(createdAtMs, isUtc: true),
      path: path,
      bytes: bytes,
      move: _Read.required<bool>(input, _Key.move),
    );
  }
}

final class _StepEncoder
    extends Converter<AndroidSaveStep, Map<Object?, Object?>> {
  const _StepEncoder();

  @override
  Map<Object?, Object?> convert(AndroidSaveStep input) => switch (input) {
    AndroidSaveStep$Copying(:final written, :final total) => {
      _Key.written: written,
      _Key.total: ?total,
    },
    AndroidSaveStep$Done(:final written, :final ref, :final renamed) => {
      _Key.written: written,
      _Key.total: written,
      _Key.done: true,
      _Key.ref: ref,
      _Key.renamed: renamed,
    },
  };
}

final class _StepDecoder
    extends Converter<Map<Object?, Object?>, AndroidSaveStep> {
  const _StepDecoder();

  @override
  AndroidSaveStep convert(Map<Object?, Object?> input) {
    final written = _Read.required<int>(input, _Key.written);
    if (_Read.optional<bool>(input, _Key.done) ?? false) {
      return AndroidSaveStep.done(
        written,
        ref: _Read.string(input, _Key.ref),
        renamed: _Read.required<bool>(input, _Key.renamed),
      );
    }
    return AndroidSaveStep.copying(
      written,
      _Read.optional<int>(input, _Key.total),
    );
  }
}

/// Typed reads of a channel map that throw a [FormatException] naming the
/// field.
abstract final class _Read {
  static String string(Map<Object?, Object?> input, String key) =>
      required<String>(input, key);

  static T required<T extends Object>(
    Map<Object?, Object?> input,
    String key,
  ) => switch (input[key]) {
    final T value => value,
    _ => throw FormatException(key, input),
  };

  static T? optional<T extends Object>(
    Map<Object?, Object?> input,
    String key,
  ) => switch (input[key]) {
    null => null,
    final T value => value,
    _ => throw FormatException(key, input),
  };
}
