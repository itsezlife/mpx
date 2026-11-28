/// The wire of Apple's save: one `saveBlock` call on the plugin's method
/// channel per batch, its arguments a [SaveBlockRequest]
/// ([SaveBlockRequestCodec]) and its answer a [SaveBlockAnswer]
/// ([SaveBlockAnswerCodec]).
///
/// ## Request
///
/// | Key | Value |
/// | --- | --- |
/// | `destination` | `gallery`, `downloads` or `ask` |
/// | `album` | the gallery's album, optional |
/// | `subfolder` | the Downloads sub-folder, optional |
/// | `entries` | a list of entry maps, in batch order |
///
/// An entry: `path` (the file to save from), `name` (the saved file's
/// name), `mime`, `kind` (`photo`, `video`, `animation` or `file`, the kind
/// to file it as), `createdMs` (optional, ms since the epoch, UTC) and
/// `move` (whether the source may be consumed; never for a cache file).
///
/// ## Answer
///
/// | Key | Value |
/// | --- | --- |
/// | `outcome` | `saved`, `failed` or `cancelled` (the export picker dismissed) |
/// | `items` | for `saved`: one map per entry, in order: `ref` (the asset's local identifier or the file's path) and `renamed` |
/// | `domain` | for `failed`: `photos` (a Photos error), `cocoa` (a Foundation file error), `posix`, or `mpx` (the plugin's own) |
/// | `code` | for `failed`: the error's code in its domain, as a string |
/// | `fallback` | optional: `noFileSharing` when Downloads went to the export picker |
/// | `album` | optional, for a named album: `added`, or `skipped` under limited access |
///
/// The block is atomic, so a failure is one for the whole batch. The native
/// side reports the error as it got it; the Dart writer maps it to a
/// `SaveFailure`.
///
/// ## Decoding
///
/// Strict: a missing or unknown required value throws a [FormatException]
/// whose message names the field, with no source: the map holds paths,
/// names and refs. Unknown keys are ignored.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';

abstract final class _Key {
  static const String destination = 'destination';
  static const String album = 'album';
  static const String subfolder = 'subfolder';
  static const String entries = 'entries';
  static const String path = 'path';
  static const String name = 'name';
  static const String mime = 'mime';
  static const String kind = 'kind';
  static const String createdMs = 'createdMs';
  static const String move = 'move';
  static const String outcome = 'outcome';
  static const String items = 'items';
  static const String ref = 'ref';
  static const String renamed = 'renamed';
  static const String domain = 'domain';
  static const String code = 'code';
  static const String fallback = 'fallback';
}

// --- Request ---

/// One `saveBlock` call: a batch to [destination].
@immutable
final class SaveBlockRequest {
  /// A block of [entries] to [destination].
  const SaveBlockRequest({required this.destination, required this.entries});

  /// Where the batch goes.
  final SaveDestination destination;

  /// The items to write, in batch order.
  final List<SaveBlockEntry> entries;

  @override
  bool operator ==(Object other) =>
      other is SaveBlockRequest &&
      other.destination == destination &&
      listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(destination, Object.hashAll(entries));
}

/// One item of a [SaveBlockRequest].
@immutable
final class SaveBlockEntry {
  /// An entry.
  const SaveBlockEntry({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.kind,
    required this.move,
    this.createdAt,
  });

  /// The file to save from.
  final String path;

  /// The saved file's name.
  final String name;

  /// Its MIME type.
  final String mimeType;

  /// What to file it as.
  final SaveItemKind kind;

  /// When it was made, written as the asset's creation date.
  final DateTime? createdAt;

  /// Whether the source may be consumed.
  final bool move;

  @override
  bool operator ==(Object other) =>
      other is SaveBlockEntry &&
      other.path == path &&
      other.name == name &&
      other.mimeType == mimeType &&
      other.kind == kind &&
      other.createdAt == createdAt &&
      other.move == move;

  @override
  int get hashCode => Object.hash(path, name, mimeType, kind, createdAt, move);
}

/// [SaveBlockRequest] ↔ the `saveBlock` arguments (see the library's format).
final class SaveBlockRequestCodec
    extends Codec<SaveBlockRequest, Map<Object?, Object?>> {
  /// The codec.
  const SaveBlockRequestCodec();

  @override
  Converter<SaveBlockRequest, Map<Object?, Object?>> get encoder =>
      const _RequestEncoder();

  @override
  Converter<Map<Object?, Object?>, SaveBlockRequest> get decoder =>
      const _RequestDecoder();
}

final class _RequestEncoder
    extends Converter<SaveBlockRequest, Map<Object?, Object?>> {
  const _RequestEncoder();

  @override
  Map<Object?, Object?> convert(SaveBlockRequest input) => {
    _Key.destination: input.destination.name,
    ...switch (input.destination) {
      SaveDestination$Gallery(:final album) => {_Key.album: ?album},
      SaveDestination$Downloads(:final subfolder) => {
        _Key.subfolder: ?subfolder,
      },
      SaveDestination$Ask() => const {},
    },
    _Key.entries: [
      for (final entry in input.entries)
        {
          _Key.path: entry.path,
          _Key.name: entry.name,
          _Key.mime: entry.mimeType,
          _Key.kind: entry.kind.name,
          _Key.createdMs: ?entry.createdAt?.millisecondsSinceEpoch,
          _Key.move: entry.move,
        },
    ],
  };
}

final class _RequestDecoder
    extends Converter<Map<Object?, Object?>, SaveBlockRequest> {
  const _RequestDecoder();

  @override
  SaveBlockRequest convert(Map<Object?, Object?> input) => SaveBlockRequest(
    destination: switch (_Read.string(input, _Key.destination)) {
      'gallery' => SaveDestination.gallery(
        album: _Read.optionalString(input, _Key.album),
      ),
      'downloads' => SaveDestination.downloads(
        subfolder: _Read.optionalString(input, _Key.subfolder),
      ),
      'ask' => const SaveDestination.ask(),
      _ => throw const FormatException(_Key.destination),
    },
    entries: [
      for (final entry in _Read.maps(input, _Key.entries))
        SaveBlockEntry(
          path: _Read.string(entry, _Key.path),
          name: _Read.string(entry, _Key.name),
          mimeType: _Read.string(entry, _Key.mime),
          kind:
              SaveItemKind.values.asNameMap()[_Read.string(entry, _Key.kind)] ??
              (throw const FormatException(_Key.kind)),
          createdAt: switch (entry[_Key.createdMs]) {
            null => null,
            final int ms => DateTime.fromMillisecondsSinceEpoch(
              ms,
              isUtc: true,
            ),
            _ => throw const FormatException(_Key.createdMs),
          },
          move: _Read.boolean(entry, _Key.move),
        ),
    ],
  );
}

// --- Answer ---

/// Why a Downloads batch went to the export picker.
enum SaveBlockFallback {
  /// The host does not show its Documents in Files
  /// (`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`).
  noFileSharing,
}

/// What became of a named album.
enum SaveBlockAlbum {
  /// The assets were added to it.
  added,

  /// Limited access cannot fetch or make an album: the assets were saved to
  /// the library without it.
  skipped,
}

/// How a `saveBlock` call ended: the whole batch at once.
@immutable
sealed class SaveBlockAnswer {
  const SaveBlockAnswer({this.fallback});

  /// Set when Downloads went to the export picker.
  final SaveBlockFallback? fallback;
}

/// Every entry saved.
final class SaveBlockAnswer$Saved extends SaveBlockAnswer {
  /// Saved as [items], one per entry in order.
  const SaveBlockAnswer$Saved(this.items, {super.fallback, this.album});

  /// One per entry.
  final List<SaveBlockSaved> items;

  /// What became of the named album; null without one.
  final SaveBlockAlbum? album;

  @override
  bool operator ==(Object other) =>
      other is SaveBlockAnswer$Saved &&
      listEquals(other.items, items) &&
      other.fallback == fallback &&
      other.album == album;

  @override
  int get hashCode => Object.hash(Object.hashAll(items), fallback, album);
}

/// The block failed: nothing of it was saved.
final class SaveBlockAnswer$Failed extends SaveBlockAnswer {
  /// Failed with [code] in [domain].
  const SaveBlockAnswer$Failed({
    required this.domain,
    required this.code,
    super.fallback,
  });

  /// The error's domain: `photos`, `cocoa`, `posix` or `mpx`.
  final String domain;

  /// The error's code in [domain].
  final String code;

  @override
  bool operator ==(Object other) =>
      other is SaveBlockAnswer$Failed &&
      other.domain == domain &&
      other.code == code &&
      other.fallback == fallback;

  @override
  int get hashCode => Object.hash(domain, code, fallback);
}

/// The user dismissed the export picker: nothing was saved.
final class SaveBlockAnswer$Cancelled extends SaveBlockAnswer {
  /// Cancelled.
  const SaveBlockAnswer$Cancelled({super.fallback});

  @override
  bool operator ==(Object other) =>
      other is SaveBlockAnswer$Cancelled && other.fallback == fallback;

  @override
  int get hashCode => Object.hash(SaveBlockAnswer$Cancelled, fallback);
}

/// One saved entry of a [SaveBlockAnswer$Saved].
@immutable
final class SaveBlockSaved {
  /// Saved as [ref].
  const SaveBlockSaved(this.ref, {this.renamed = false});

  /// The asset's local identifier, or the saved file's path.
  final String ref;

  /// Whether a taken name made it another.
  final bool renamed;

  @override
  bool operator ==(Object other) =>
      other is SaveBlockSaved && other.ref == ref && other.renamed == renamed;

  @override
  int get hashCode => Object.hash(ref, renamed);
}

/// [SaveBlockAnswer] ↔ the `saveBlock` answer (see the library's format).
final class SaveBlockAnswerCodec
    extends Codec<SaveBlockAnswer, Map<Object?, Object?>> {
  /// The codec.
  const SaveBlockAnswerCodec();

  @override
  Converter<SaveBlockAnswer, Map<Object?, Object?>> get encoder =>
      const _AnswerEncoder();

  @override
  Converter<Map<Object?, Object?>, SaveBlockAnswer> get decoder =>
      const _AnswerDecoder();
}

final class _AnswerEncoder
    extends Converter<SaveBlockAnswer, Map<Object?, Object?>> {
  const _AnswerEncoder();

  @override
  Map<Object?, Object?> convert(SaveBlockAnswer input) => {
    ...switch (input) {
      SaveBlockAnswer$Saved(:final items, :final album) => {
        _Key.outcome: 'saved',
        _Key.items: [
          for (final item in items)
            {_Key.ref: item.ref, _Key.renamed: item.renamed},
        ],
        _Key.album: ?album?.name,
      },
      SaveBlockAnswer$Failed(:final domain, :final code) => {
        _Key.outcome: 'failed',
        _Key.domain: domain,
        _Key.code: code,
      },
      SaveBlockAnswer$Cancelled() => {_Key.outcome: 'cancelled'},
    },
    _Key.fallback: ?input.fallback?.name,
  };
}

final class _AnswerDecoder
    extends Converter<Map<Object?, Object?>, SaveBlockAnswer> {
  const _AnswerDecoder();

  @override
  SaveBlockAnswer convert(Map<Object?, Object?> input) {
    final fallback = switch (_Read.optionalString(input, _Key.fallback)) {
      null => null,
      final name =>
        SaveBlockFallback.values.asNameMap()[name] ??
            (throw const FormatException(_Key.fallback)),
    };
    return switch (_Read.string(input, _Key.outcome)) {
      'saved' => SaveBlockAnswer$Saved(
        [
          for (final item in _Read.maps(input, _Key.items))
            SaveBlockSaved(
              _Read.string(item, _Key.ref),
              renamed: _Read.boolean(item, _Key.renamed),
            ),
        ],
        fallback: fallback,
        album: switch (_Read.optionalString(input, _Key.album)) {
          null => null,
          final name =>
            SaveBlockAlbum.values.asNameMap()[name] ??
                (throw const FormatException(_Key.album)),
        },
      ),
      'failed' => SaveBlockAnswer$Failed(
        domain: _Read.string(input, _Key.domain),
        code: _Read.string(input, _Key.code),
        fallback: fallback,
      ),
      'cancelled' => SaveBlockAnswer$Cancelled(fallback: fallback),
      _ => throw const FormatException(_Key.outcome),
    };
  }
}

/// Typed reads that name the field they fail on.
abstract final class _Read {
  static String string(Map<Object?, Object?> map, String key) =>
      switch (map[key]) {
        final String value => value,
        _ => throw FormatException(key),
      };

  static String? optionalString(Map<Object?, Object?> map, String key) =>
      switch (map[key]) {
        null => null,
        final String value => value,
        _ => throw FormatException(key),
      };

  static bool boolean(Map<Object?, Object?> map, String key) =>
      switch (map[key]) {
        final bool value => value,
        _ => throw FormatException(key),
      };

  static List<Map<Object?, Object?>> maps(
    Map<Object?, Object?> map,
    String key,
  ) => switch (map[key]) {
    final List<Object?> list => [
      for (final element in list)
        switch (element) {
          final Map<Object?, Object?> entry => entry,
          _ => throw FormatException(key),
        },
    ],
    _ => throw FormatException(key),
  };
}
