import 'dart:convert';

import 'package:meta/meta.dart';

/// The identity of a piece of media: which media, never where it lives.
///
/// A key is never a URL. Where the bytes come from is the fetcher's business,
/// keyed by the media key; the same media fetched from two mirrors is one key.
/// The set of variants is closed:
///
/// - [MediaKey.remote]: an opaque id the host's own backend issues.
/// - [MediaKey.external]: an opaque id of media from outside that backend,
///   such as a web search result.
/// - [MediaKey.local]: a file produced on this device (a capture, a
///   compression output), named by a UUID from the moment it starts, before
///   any backend knows it.
///
/// Equality is exact value equality on the payload, per variant: the same id
/// under two variants is two keys. Credentials and provenance are not part of
/// a key; the host that fetches keeps them, keyed by it.
///
/// ## Stable string form
///
/// [encoded] is a stable string that [parse] and [tryParse] read back to an
/// equal key. It is safe as a file name and as a cache key on every platform:
/// only `A-Z a-z 0-9 . _ ~ -` and `%` escapes.
///
/// | Variant | Encoding | Example |
/// | --- | --- | --- |
/// | remote | `remote-` and the escaped id | `remote-5368` |
/// | external | `external-` and the escaped id | `external-https%3A%2F%2Fhost%2Fa` |
/// | local | `local-` and the UUID in lower case | `local-3f1c2a7e-9b4d-4c1e-8a2f-0d5e6b7c8a91` |
///
/// The id is escaped as UTF-8 bytes, `%` and two upper-case hex digits for
/// every byte outside the safe set. Output is canonical; input takes the hex
/// digits in either case. The form has no length limit: a store with one
/// hashes long forms.
@immutable
sealed class MediaKey {
  /// A key for the media the host's backend calls [id].
  ///
  /// [id] must not be empty.
  const factory MediaKey.remote(String id) = MediaKey$Remote;

  /// A key for media from outside the host's backend, called [id] there.
  ///
  /// [id] must not be empty.
  const factory MediaKey.external(String id) = MediaKey$External;

  /// A key for a file produced on this device, named by [uuid].
  ///
  /// [uuid] is the 8-4-4-4-12 hex form, in either case; the key keeps it in
  /// lower case. Throws an [ArgumentError] for anything else.
  factory MediaKey.local(String uuid) = MediaKey$Local;

  /// The key [encoded] was produced from.
  ///
  /// Throws a [FormatException] carrying [source] when it is not an encoded
  /// key. Use [tryParse] for persisted data that may be damaged or written by
  /// another version.
  factory MediaKey.parse(String source) =>
      tryParse(source) ??
      (throw FormatException('Not an encoded MediaKey.', source));

  const MediaKey._();

  /// The key [source] encodes, or null when it is not an encoded key: no
  /// known variant prefix, an empty payload, a character outside the safe set,
  /// a broken escape, or a local payload that is not a UUID.
  static MediaKey? tryParse(String? source) {
    if (source == null) return null;
    final separator = source.indexOf('-');
    if (separator < 0) return null;
    final payload = source.substring(separator + 1);
    if (payload.isEmpty) return null;
    return switch (source.substring(0, separator)) {
      _remoteTag => switch (_unescape(payload)) {
        final id? => MediaKey$Remote(id),
        null => null,
      },
      _externalTag => switch (_unescape(payload)) {
        final id? => MediaKey$External(id),
        null => null,
      },
      _localTag when MediaKey$Local._uuidShape.hasMatch(payload) =>
        MediaKey$Local(payload),
      _ => null,
    };
  }

  /// The stable string form of this key; see the encoding table of
  /// [MediaKey].
  String get encoded;

  static const String _remoteTag = 'remote';
  static const String _externalTag = 'external';
  static const String _localTag = 'local';

  static final RegExp _escapedShape = RegExp(
    r'^(?:[A-Za-z0-9._~-]|%[0-9A-Fa-f]{2})+$',
  );

  static bool _isSafe(int byte) =>
      (byte >= 0x30 && byte <= 0x39) || // 0-9
      (byte >= 0x41 && byte <= 0x5A) || // A-Z
      (byte >= 0x61 && byte <= 0x7A) || // a-z
      byte == 0x2E || // .
      byte == 0x5F || // _
      byte == 0x7E || // ~
      byte == 0x2D; // -

  static String _escape(String id) {
    final out = StringBuffer();
    for (final byte in utf8.encode(id)) {
      if (_isSafe(byte)) {
        out.writeCharCode(byte);
      } else {
        out
          ..write('%')
          ..write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return out.toString();
  }

  // Null for anything [_escape] could not have written: a character outside
  // the safe set, a broken escape, or escapes that are not UTF-8.
  static String? _unescape(String payload) {
    if (!_escapedShape.hasMatch(payload)) return null;
    final bytes = <int>[];
    for (var i = 0; i < payload.length; i++) {
      final unit = payload.codeUnitAt(i);
      if (unit == 0x25) {
        bytes.add(int.parse(payload.substring(i + 1, i + 3), radix: 16));
        i += 2;
      } else {
        bytes.add(unit);
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }
}

/// A [MediaKey] for media the host's backend names; see [MediaKey.remote].
final class MediaKey$Remote extends MediaKey {
  /// Creates the key for [id], which must not be empty.
  const MediaKey$Remote(this.id)
    : assert(id != '', 'A remote MediaKey needs an id.'),
      super._();

  /// The opaque id. A string rather than an integer so 64-bit ids survive
  /// targets whose integers are doubles.
  final String id;

  @override
  String get encoded => '${MediaKey._remoteTag}-${MediaKey._escape(id)}';

  @override
  bool operator ==(Object other) => other is MediaKey$Remote && other.id == id;

  @override
  int get hashCode => Object.hash(MediaKey$Remote, id);

  @override
  String toString() => 'MediaKey.remote($id)';
}

/// A [MediaKey] for media from outside the host's backend; see
/// [MediaKey.external].
final class MediaKey$External extends MediaKey {
  /// Creates the key for [id], which must not be empty.
  const MediaKey$External(this.id)
    : assert(id != '', 'An external MediaKey needs an id.'),
      super._();

  /// The opaque id of the media where it comes from.
  final String id;

  @override
  String get encoded => '${MediaKey._externalTag}-${MediaKey._escape(id)}';

  @override
  bool operator ==(Object other) =>
      other is MediaKey$External && other.id == id;

  @override
  int get hashCode => Object.hash(MediaKey$External, id);

  @override
  String toString() => 'MediaKey.external($id)';
}

/// A [MediaKey] for a file produced on this device; see [MediaKey.local].
final class MediaKey$Local extends MediaKey {
  /// Creates the key for [uuid]; throws an [ArgumentError] when it is not a
  /// UUID in the 8-4-4-4-12 hex form.
  factory MediaKey$Local(String uuid) {
    if (!_uuidShape.hasMatch(uuid)) {
      throw ArgumentError.value(uuid, 'uuid', 'Not a UUID');
    }
    // Canonical at construction, so two spellings of one UUID are one key
    // everywhere a key is compared or hashed.
    return MediaKey$Local._(uuid.toLowerCase());
  }

  const MediaKey$Local._(this.uuid) : super._();

  static final RegExp _uuidShape = RegExp(
    r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
  );

  /// The UUID, in lower case.
  final String uuid;

  @override
  String get encoded => '${MediaKey._localTag}-$uuid';

  @override
  bool operator ==(Object other) =>
      other is MediaKey$Local && other.uuid == uuid;

  @override
  int get hashCode => Object.hash(MediaKey$Local, uuid);

  @override
  String toString() => 'MediaKey.local($uuid)';
}
