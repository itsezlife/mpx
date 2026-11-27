import 'package:meta/meta.dart';

/// Typed reads of one JSON object the package stored: a journal record, a
/// reuse entry, a result.
///
/// Every decoder of the package reads the same few shapes (a string, an
/// integer, a flag, a time, a name of an enum, a nested object or list),
/// required or optional. A bare `json['x']! as String` fails a bad record
/// with a `TypeError` that names neither the field nor the record; each
/// read here fails with a [FormatException] naming the field, its
/// [FormatException.source] the object read, so a skipped record says
/// why. An optional read takes a missing field and a JSON `null` alike.
///
/// Internal to the package.
@internal
extension type const JsonFields(Map<String, Object?> json) {
  /// [value] read as an object; [what] names it in the error.
  static JsonFields of(Object? value, {required String what}) =>
      switch (value) {
        final Map<String, Object?> json => JsonFields(json),
        _ => throw FormatException('Expected $what to be an object.', value),
      };

  // --- Scalars ---------------------------------------------------------------

  /// The string under [key].
  String string(String key) => _required<String>(key, 'a string');

  /// The string under [key], or null.
  String? optionalString(String key) => _optional<String>(key, 'a string');

  /// The integer under [key].
  int integer(String key) => _required<int>(key, 'an integer');

  /// The integer under [key], or null.
  int? optionalInteger(String key) => _optional<int>(key, 'an integer');

  /// The number under [key] as a double, or null.
  double? optionalNumber(String key) =>
      _optional<num>(key, 'a number')?.toDouble();

  /// The flag under [key].
  bool flag(String key) => _required<bool>(key, 'a flag');

  /// The flag under [key]; false when missing, as the encoders leave a
  /// false flag out.
  bool optionalFlag(String key) => _optional<bool>(key, 'a flag') ?? false;

  /// The ISO 8601 time under [key].
  DateTime time(String key) => _parseTime(key, string(key));

  /// The ISO 8601 time under [key], or null.
  DateTime? optionalTime(String key) => switch (optionalString(key)) {
    final value? => _parseTime(key, value),
    null => null,
  };

  /// The value of [values] named under [key].
  T byName<T extends Enum>(List<T> values, String key) =>
      _named(values, key, string(key));

  /// The value of [values] named under [key], or null.
  T? optionalByName<T extends Enum>(List<T> values, String key) =>
      switch (optionalString(key)) {
        final name? => _named(values, key, name),
        null => null,
      };

  // --- Nested ----------------------------------------------------------------

  /// The object under [key].
  JsonFields object(String key) =>
      JsonFields(_required<Map<String, Object?>>(key, 'an object'));

  /// The object under [key], or null.
  JsonFields? optionalObject(String key) =>
      switch (_optional<Map<String, Object?>>(key, 'an object')) {
        final json? => JsonFields(json),
        null => null,
      };

  /// The list under [key].
  List<Object?> list(String key) => _required<List<Object?>>(key, 'a list');

  /// The list under [key]; empty when missing, as the encoders leave an
  /// empty list out.
  List<Object?> optionalList(String key) =>
      _optional<List<Object?>>(key, 'a list') ?? const [];

  /// The strings of the list under [key]; empty when missing.
  List<String> optionalStrings(String key) => [
    for (final value in optionalList(key))
      switch (value) {
        final String text => text,
        _ => throw FormatException('Expected strings under "$key".', json),
      },
  ];

  /// The objects of the list under [key].
  List<JsonFields> objects(String key) => [
    for (final value in list(key))
      JsonFields.of(value, what: 'an entry of "$key"'),
  ];

  /// The string-to-string object under [key]; empty when missing.
  Map<String, String> optionalStringMap(String key) => {
    for (final MapEntry(key: name, :value)
        in (optionalObject(key)?.json ?? const <String, Object?>{}).entries)
      name: switch (value) {
        final String text => text,
        _ => throw FormatException('Expected strings under "$key".', json),
      },
  };

  // --- Machinery -------------------------------------------------------------

  T _required<T extends Object>(String key, String expected) =>
      switch (json[key]) {
        final T value => value,
        null => throw FormatException('Missing "$key".', json),
        _ => throw FormatException('Expected $expected under "$key".', json),
      };

  T? _optional<T extends Object>(String key, String expected) =>
      switch (json[key]) {
        null => null,
        final T value => value,
        _ => throw FormatException('Expected $expected under "$key".', json),
      };

  DateTime _parseTime(String key, String value) =>
      DateTime.tryParse(value) ??
      (throw FormatException('Expected an ISO 8601 time under "$key".', json));

  T _named<T extends Enum>(List<T> values, String key, String name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown "$name" under "$key".', json);
  }
}
