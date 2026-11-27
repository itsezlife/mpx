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
/// Stable: a key or a name written by one version is read by every later
/// one. Enums are stored by name (`CompressionPreset.name`,
/// `PreparedKind.name`), durations in microseconds. A map of a [version]
/// this code does not know, a missing key or an unknown name fails with a
/// [FormatException], never with a guess.
///
/// In-memory bytes are not stored: `PreparedMedia.thumbnail` and
/// `PreparedMedia.bytes` decode as null. A prepared item that must survive
/// a restart names its thumbnail by `PreparedMedia.thumbnailPath`.
abstract final class PreparationEncoding {
  /// The version every map this code writes carries.
  static const int version = 1;

  /// [input] in its stored form.
  static Map<String, Object?> encodeInput(PreparationInput input) => {
    _version: version,
    'path': input.path,
    'mimeType': input.mimeType,
    'byteSize': input.byteSize,
  };

  /// The input [encoded] stores.
  static PreparationInput decodeInput(Map<String, Object?> encoded) {
    _checkVersion(encoded);
    return PreparationInput(
      _required<String>(encoded, 'path'),
      mimeType: _optional<String>(encoded, 'mimeType'),
      byteSize: _optional<int>(encoded, 'byteSize'),
    );
  }

  /// [intent] in its stored form.
  static Map<String, Object?> encodeIntent(PreparationIntent intent) => {
    _version: version,
    ...switch (intent) {
      PreparationIntent$Photo(:final highQuality) => {
        'as': 'photo',
        'highQuality': highQuality,
      },
      PreparationIntent$Video(:final preset) => {
        'as': 'video',
        'preset': preset?.name,
      },
      PreparationIntent$File() => {'as': 'file'},
    },
  };

  /// The intent [encoded] stores.
  static PreparationIntent decodeIntent(Map<String, Object?> encoded) {
    _checkVersion(encoded);
    return switch (_required<String>(encoded, 'as')) {
      'photo' => PreparationIntent.photo(
        highQuality: _required<bool>(encoded, 'highQuality'),
      ),
      'video' => PreparationIntent.video(
        preset: switch (_optional<String>(encoded, 'preset')) {
          null => null,
          final name => _byName(CompressionPreset.values, name, 'preset'),
        },
      ),
      'file' => const PreparationIntent.file(),
      final other => throw FormatException('Unknown intent "$other".'),
    };
  }

  /// [media] in its stored form, without its in-memory bytes.
  static Map<String, Object?> encodePrepared(PreparedMedia media) => {
    _version: version,
    'kind': media.kind.name,
    'path': media.path,
    'isOriginal': media.isOriginal,
    'byteSize': media.byteSize,
    'mimeType': media.mimeType,
    'width': media.dimensions?.width,
    'height': media.dimensions?.height,
    'durationUs': media.duration?.inMicroseconds,
    'thumbnailPath': media.thumbnailPath,
    'thumbnailWidth': media.thumbnailDimensions?.width,
    'thumbnailHeight': media.thumbnailDimensions?.height,
    'hasAudio': media.hasAudio,
    'animated': media.animated,
  };

  /// The prepared item [encoded] stores; its in-memory bytes are null.
  static PreparedMedia decodePrepared(Map<String, Object?> encoded) {
    _checkVersion(encoded);
    final durationUs = _optional<int>(encoded, 'durationUs');
    return PreparedMedia(
      kind: _byName(
        PreparedKind.values,
        _required<String>(encoded, 'kind'),
        'kind',
      ),
      path: _required<String>(encoded, 'path'),
      isOriginal: _required<bool>(encoded, 'isOriginal'),
      byteSize: _required<int>(encoded, 'byteSize'),
      mimeType: _optional<String>(encoded, 'mimeType'),
      dimensions: _dimensions(encoded, 'width', 'height'),
      duration: durationUs == null ? null : Duration(microseconds: durationUs),
      thumbnailPath: _optional<String>(encoded, 'thumbnailPath'),
      thumbnailDimensions: _dimensions(
        encoded,
        'thumbnailWidth',
        'thumbnailHeight',
      ),
      hasAudio: _required<bool>(encoded, 'hasAudio'),
      animated: _required<bool>(encoded, 'animated'),
    );
  }

  static const String _version = 'v';

  static void _checkVersion(Map<String, Object?> encoded) {
    final found = encoded[_version];
    if (found != version) {
      throw FormatException('Unknown preparation encoding version "$found".');
    }
  }

  static T _required<T extends Object>(Map<String, Object?> map, String key) =>
      switch (map[key]) {
        final T value => value,
        final other => throw FormatException(
          'Expected $T under "$key", found ${other.runtimeType}.',
        ),
      };

  static T? _optional<T extends Object>(Map<String, Object?> map, String key) =>
      switch (map[key]) {
        null => null,
        final T value => value,
        final other => throw FormatException(
          'Expected $T or null under "$key", found ${other.runtimeType}.',
        ),
      };

  static T _byName<T extends Enum>(List<T> values, String name, String key) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown $key "$name".');
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
      throw FormatException('Non-positive size under "$widthKey".');
    }
    return MediaDimensions(width, height);
  }
}
