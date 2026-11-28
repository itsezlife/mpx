/// The stored form of the preparation values: what a journal and a reuse
/// table write for an item's input, its intent and its prepared file, and
/// read back after a restart.
///
/// Each value encodes to a JSON-safe map (strings, integers, booleans, null)
/// carrying the form's version under `v`, through its codec:
/// [PreparationInputCodec], [PreparationIntentCodec] and
/// [PreparedMediaCodec]. The values themselves know no stored form: these
/// codecs are the one place it lives, so a store never builds or parses
/// these maps by hand.
///
/// ## Fields
///
/// | Value | Keys |
/// |---|---|
/// | [PreparationInput] | `path`, `mimeType`, `byteSize` |
/// | [PreparationIntent] | `as` (`photo`, `video`, `file`); `highQuality` for a photo, `preset` for a video |
/// | [PreparedMedia] | `kind`, `path`, `isOriginal`, `byteSize`, `mimeType`, `width`, `height`, `durationUs`, `thumbnailPath`, `thumbnailWidth`, `thumbnailHeight`, `hasAudio`, `animated` |
///
/// ## Encoding
///
/// Every key is written, in the order above after `v`, an absent value as
/// null. Enums are stored by name (`CompressionPreset.name`,
/// `PreparedKind.name`), durations in microseconds, a size as its width and
/// height side by side.
///
/// In-memory bytes are not stored: `PreparedMedia.thumbnail` and
/// `PreparedMedia.bytes` decode as null. A prepared item that must survive
/// a restart names its thumbnail by `PreparedMedia.thumbnailPath`.
///
/// ## Decoding
///
/// A missing key reads as null where the value is optional. A missing
/// required key, a value of the wrong type, an unknown name, a size that is
/// not positive and a map of a version this code does not know each fail
/// with a [FormatException] naming the key, its source the map read; never
/// with a guess.
///
/// ## Versioning
///
/// Stable: a key or a name written by one version is read by every later
/// one. A change an older reader would misread takes a new version, the
/// same for the three codecs.
library;

import 'dart:convert';

import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/preparation/compression_preset.dart';
import 'package:mpx_core/src/preparation/preparation_input.dart';
import 'package:mpx_core/src/preparation/prepared_media.dart';

/// A [PreparationInput] to and from its stored map (see the library docs).
final class PreparationInputCodec
    extends Codec<PreparationInput, Map<String, Object?>> {
  /// The codec.
  const PreparationInputCodec();

  /// The version every input map written carries.
  static const int version = _version;

  @override
  Converter<PreparationInput, Map<String, Object?>> get encoder =>
      const _InputEncoder();

  @override
  Converter<Map<String, Object?>, PreparationInput> get decoder =>
      const _InputDecoder();
}

/// A [PreparationIntent] to and from its stored map (see the library docs).
final class PreparationIntentCodec
    extends Codec<PreparationIntent, Map<String, Object?>> {
  /// The codec.
  const PreparationIntentCodec();

  /// The version every intent map written carries.
  static const int version = _version;

  @override
  Converter<PreparationIntent, Map<String, Object?>> get encoder =>
      const _IntentEncoder();

  @override
  Converter<Map<String, Object?>, PreparationIntent> get decoder =>
      const _IntentDecoder();
}

/// A [PreparedMedia] to and from its stored map, without its in-memory
/// bytes (see the library docs).
final class PreparedMediaCodec
    extends Codec<PreparedMedia, Map<String, Object?>> {
  /// The codec.
  const PreparedMediaCodec();

  /// The version every prepared-file map written carries.
  static const int version = _version;

  @override
  Converter<PreparedMedia, Map<String, Object?>> get encoder =>
      const _PreparedEncoder();

  @override
  Converter<Map<String, Object?>, PreparedMedia> get decoder =>
      const _PreparedDecoder();
}

/// The version of all three forms: they change together.
const int _version = 1;

/// Keys of the stored maps, shared by both directions.
abstract final class _Key {
  static const String version = 'v';

  // An input, and a prepared file.
  static const String path = 'path';
  static const String mimeType = 'mimeType';
  static const String byteSize = 'byteSize';

  // An intent.
  static const String as = 'as';
  static const String highQuality = 'highQuality';
  static const String preset = 'preset';

  // A prepared file.
  static const String kind = 'kind';
  static const String isOriginal = 'isOriginal';
  static const String width = 'width';
  static const String height = 'height';
  static const String durationUs = 'durationUs';
  static const String thumbnailPath = 'thumbnailPath';
  static const String thumbnailWidth = 'thumbnailWidth';
  static const String thumbnailHeight = 'thumbnailHeight';
  static const String hasAudio = 'hasAudio';
  static const String animated = 'animated';
}

/// The `as` names of an intent.
abstract final class _As {
  static const String photo = 'photo';
  static const String video = 'video';
  static const String file = 'file';
}

// --- Input ------------------------------------------------------------------

final class _InputEncoder
    extends Converter<PreparationInput, Map<String, Object?>> {
  const _InputEncoder();

  @override
  Map<String, Object?> convert(PreparationInput input) => {
    _Key.version: _version,
    _Key.path: input.path,
    _Key.mimeType: input.mimeType,
    _Key.byteSize: input.byteSize,
  };
}

final class _InputDecoder
    extends Converter<Map<String, Object?>, PreparationInput> {
  const _InputDecoder();

  @override
  PreparationInput convert(Map<String, Object?> input) {
    final read = _Read(input);
    return PreparationInput(
      read.required<String>(_Key.path),
      mimeType: read.optional<String>(_Key.mimeType),
      byteSize: read.optional<int>(_Key.byteSize),
    );
  }
}

// --- Intent -----------------------------------------------------------------

final class _IntentEncoder
    extends Converter<PreparationIntent, Map<String, Object?>> {
  const _IntentEncoder();

  @override
  Map<String, Object?> convert(PreparationIntent input) => {
    _Key.version: _version,
    ...switch (input) {
      PreparationIntent$Photo(:final highQuality) => {
        _Key.as: _As.photo,
        _Key.highQuality: highQuality,
      },
      PreparationIntent$Video(:final preset) => {
        _Key.as: _As.video,
        _Key.preset: preset?.name,
      },
      PreparationIntent$File() => {_Key.as: _As.file},
    },
  };
}

final class _IntentDecoder
    extends Converter<Map<String, Object?>, PreparationIntent> {
  const _IntentDecoder();

  @override
  PreparationIntent convert(Map<String, Object?> input) {
    final read = _Read(input);
    return switch (read.required<String>(_Key.as)) {
      _As.photo => PreparationIntent.photo(
        highQuality: read.required<bool>(_Key.highQuality),
      ),
      _As.video => PreparationIntent.video(
        preset: switch (read.optional<String>(_Key.preset)) {
          null => null,
          final name => read.byName(
            CompressionPreset.values,
            name,
            _Key.preset,
          ),
        },
      ),
      _As.file => const PreparationIntent.file(),
      final other => throw FormatException(
        'Unknown intent "$other" under "${_Key.as}".',
        input,
      ),
    };
  }
}

// --- Prepared file ----------------------------------------------------------

final class _PreparedEncoder
    extends Converter<PreparedMedia, Map<String, Object?>> {
  const _PreparedEncoder();

  @override
  Map<String, Object?> convert(PreparedMedia input) => {
    _Key.version: _version,
    _Key.kind: input.kind.name,
    _Key.path: input.path,
    _Key.isOriginal: input.isOriginal,
    _Key.byteSize: input.byteSize,
    _Key.mimeType: input.mimeType,
    _Key.width: input.dimensions?.width,
    _Key.height: input.dimensions?.height,
    _Key.durationUs: input.duration?.inMicroseconds,
    _Key.thumbnailPath: input.thumbnailPath,
    _Key.thumbnailWidth: input.thumbnailDimensions?.width,
    _Key.thumbnailHeight: input.thumbnailDimensions?.height,
    _Key.hasAudio: input.hasAudio,
    _Key.animated: input.animated,
  };
}

final class _PreparedDecoder
    extends Converter<Map<String, Object?>, PreparedMedia> {
  const _PreparedDecoder();

  @override
  PreparedMedia convert(Map<String, Object?> input) {
    final read = _Read(input);
    return PreparedMedia(
      kind: read.byName(
        PreparedKind.values,
        read.required<String>(_Key.kind),
        _Key.kind,
      ),
      path: read.required<String>(_Key.path),
      isOriginal: read.required<bool>(_Key.isOriginal),
      byteSize: read.required<int>(_Key.byteSize),
      mimeType: read.optional<String>(_Key.mimeType),
      dimensions: read.dimensions(_Key.width, _Key.height),
      duration: switch (read.optional<int>(_Key.durationUs)) {
        final microseconds? => Duration(microseconds: microseconds),
        null => null,
      },
      thumbnailPath: read.optional<String>(_Key.thumbnailPath),
      thumbnailDimensions: read.dimensions(
        _Key.thumbnailWidth,
        _Key.thumbnailHeight,
      ),
      hasAudio: read.required<bool>(_Key.hasAudio),
      animated: read.required<bool>(_Key.animated),
    );
  }
}

// --- Read shapes ------------------------------------------------------------

/// Typed reads of one stored map, its version checked on the way in; every
/// failure is a [FormatException] naming the key, its source the map.
extension type _Read._(Map<String, Object?> map) {
  _Read(this.map) {
    final found = map[_Key.version];
    if (found != _version) {
      throw FormatException(
        'Unknown preparation encoding version "$found".',
        map,
      );
    }
  }

  T required<T extends Object>(String key) => switch (map[key]) {
    final T value => value,
    null => throw FormatException('Missing "$key".', map),
    final other => throw FormatException(
      'Expected $T under "$key", found ${other.runtimeType}.',
      map,
    ),
  };

  T? optional<T extends Object>(String key) => switch (map[key]) {
    null => null,
    final T value => value,
    final other => throw FormatException(
      'Expected $T or null under "$key", found ${other.runtimeType}.',
      map,
    ),
  };

  T byName<T extends Enum>(List<T> values, String name, String key) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown $key "$name".', map);
  }

  MediaDimensions? dimensions(String widthKey, String heightKey) {
    final width = optional<int>(widthKey);
    final height = optional<int>(heightKey);
    if (width == null || height == null) return null;
    if (width <= 0 || height <= 0) {
      throw FormatException('Non-positive size under "$widthKey".', map);
    }
    return MediaDimensions(width, height);
  }
}
