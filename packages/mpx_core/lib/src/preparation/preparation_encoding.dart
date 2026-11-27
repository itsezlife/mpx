import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/preparation/compression_preset.dart';
import 'package:mpx_core/src/preparation/preparation_input.dart';
import 'package:mpx_core/src/preparation/prepared_media.dart';

/// The stored form of the preparation values: what a journal and a reuse
/// table write for an item's input, its intent and its prepared file, and
/// read back after a restart.
///
/// Each value encodes to a JSON-safe map (strings, integers, booleans, null)
/// carrying the encoding's version under `v`. The values themselves know no
/// stored form: this is the one place it lives, so a store never builds or
/// parses these maps by hand.
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
/// Every key is written, an absent value as null. Enums are stored by name
/// (`CompressionPreset.name`, `PreparedKind.name`), durations in
/// microseconds, a size as its width and height side by side.
///
/// In-memory bytes are not stored: `PreparedMedia.thumbnail` and
/// `PreparedMedia.bytes` decode as null. A prepared item that must survive
/// a restart names its thumbnail by `PreparedMedia.thumbnailPath`.
///
/// ## Decoding
///
/// A missing key reads as null where the value is optional. A missing
/// required key, a value of the wrong type, an unknown name, a size that is
/// not positive and a map of a [version] this code does not know each fail
/// with a [FormatException] naming the key, its source the map read; never
/// with a guess.
///
/// ## Versioning
///
/// Stable: a key or a name written by one version is read by every later
/// one. A change an older reader would misread takes a new [version].
abstract final class PreparationEncoding {
  /// The version every map this code writes carries.
  static const int version = 1;

  /// [input] in its stored form.
  static Map<String, Object?> encodeInput(PreparationInput input) => {
    _Key.version: version,
    _Key.path: input.path,
    _Key.mimeType: input.mimeType,
    _Key.byteSize: input.byteSize,
  };

  /// The input [encoded] stores.
  static PreparationInput decodeInput(Map<String, Object?> encoded) {
    _checkVersion(encoded);
    return PreparationInput(
      _required<String>(encoded, _Key.path),
      mimeType: _optional<String>(encoded, _Key.mimeType),
      byteSize: _optional<int>(encoded, _Key.byteSize),
    );
  }

  /// [intent] in its stored form.
  static Map<String, Object?> encodeIntent(PreparationIntent intent) => {
    _Key.version: version,
    ...switch (intent) {
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

  /// The intent [encoded] stores.
  static PreparationIntent decodeIntent(Map<String, Object?> encoded) {
    _checkVersion(encoded);
    return switch (_required<String>(encoded, _Key.as)) {
      _As.photo => PreparationIntent.photo(
        highQuality: _required<bool>(encoded, _Key.highQuality),
      ),
      _As.video => PreparationIntent.video(
        preset: switch (_optional<String>(encoded, _Key.preset)) {
          null => null,
          final name => _byName(
            CompressionPreset.values,
            name,
            _Key.preset,
            encoded,
          ),
        },
      ),
      _As.file => const PreparationIntent.file(),
      final other => throw FormatException(
        'Unknown intent "$other" under "${_Key.as}".',
        encoded,
      ),
    };
  }

  /// [media] in its stored form, without its in-memory bytes.
  static Map<String, Object?> encodePrepared(PreparedMedia media) => {
    _Key.version: version,
    _Key.kind: media.kind.name,
    _Key.path: media.path,
    _Key.isOriginal: media.isOriginal,
    _Key.byteSize: media.byteSize,
    _Key.mimeType: media.mimeType,
    _Key.width: media.dimensions?.width,
    _Key.height: media.dimensions?.height,
    _Key.durationUs: media.duration?.inMicroseconds,
    _Key.thumbnailPath: media.thumbnailPath,
    _Key.thumbnailWidth: media.thumbnailDimensions?.width,
    _Key.thumbnailHeight: media.thumbnailDimensions?.height,
    _Key.hasAudio: media.hasAudio,
    _Key.animated: media.animated,
  };

  /// The prepared item [encoded] stores; its in-memory bytes are null.
  static PreparedMedia decodePrepared(Map<String, Object?> encoded) {
    _checkVersion(encoded);
    return PreparedMedia(
      kind: _byName(
        PreparedKind.values,
        _required<String>(encoded, _Key.kind),
        _Key.kind,
        encoded,
      ),
      path: _required<String>(encoded, _Key.path),
      isOriginal: _required<bool>(encoded, _Key.isOriginal),
      byteSize: _required<int>(encoded, _Key.byteSize),
      mimeType: _optional<String>(encoded, _Key.mimeType),
      dimensions: _dimensions(encoded, _Key.width, _Key.height),
      duration: switch (_optional<int>(encoded, _Key.durationUs)) {
        final microseconds? => Duration(microseconds: microseconds),
        null => null,
      },
      thumbnailPath: _optional<String>(encoded, _Key.thumbnailPath),
      thumbnailDimensions: _dimensions(
        encoded,
        _Key.thumbnailWidth,
        _Key.thumbnailHeight,
      ),
      hasAudio: _required<bool>(encoded, _Key.hasAudio),
      animated: _required<bool>(encoded, _Key.animated),
    );
  }

  // --- Read shapes -----------------------------------------------------------

  static void _checkVersion(Map<String, Object?> encoded) {
    final found = encoded[_Key.version];
    if (found != version) {
      throw FormatException(
        'Unknown preparation encoding version "$found".',
        encoded,
      );
    }
  }

  static T _required<T extends Object>(Map<String, Object?> map, String key) =>
      switch (map[key]) {
        final T value => value,
        null => throw FormatException('Missing "$key".', map),
        final other => throw FormatException(
          'Expected $T under "$key", found ${other.runtimeType}.',
          map,
        ),
      };

  static T? _optional<T extends Object>(Map<String, Object?> map, String key) =>
      switch (map[key]) {
        null => null,
        final T value => value,
        final other => throw FormatException(
          'Expected $T or null under "$key", found ${other.runtimeType}.',
          map,
        ),
      };

  static T _byName<T extends Enum>(
    List<T> values,
    String name,
    String key,
    Map<String, Object?> map,
  ) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown $key "$name".', map);
  }

  static MediaDimensions? _dimensions(
    Map<String, Object?> map,
    String widthKey,
    String heightKey,
  ) {
    final width = _optional<int>(map, widthKey);
    final height = _optional<int>(map, heightKey);
    if (width == null || height == null) return null;
    if (width <= 0 || height <= 0) {
      throw FormatException('Non-positive size under "$widthKey".', map);
    }
    return MediaDimensions(width, height);
  }
}

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
