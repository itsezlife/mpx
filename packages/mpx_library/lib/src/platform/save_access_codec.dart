import 'dart:convert';

import 'package:mpx_library/src/save/save_access.dart';
import 'package:mpx_library/src/save/save_admission.dart';

/// [SaveAccessAnswer] ↔ the map the native save access answers with, on
/// the plugin's method channel (`saveAccess` reads, `requestSaveAccess`
/// asks; both take `destination`, the destination's name, and `album`,
/// whether a named album was given).
///
/// ## Format
///
/// | Key | Value |
/// | --- | --- |
/// | `scope` | `none`, `addOnly`, `readWrite` or `legacyWrite`: the grant |
/// | `status` | `notDetermined`, `denied`, `restricted`, `limited`, `authorized` or `unavailable` |
/// | `missing` | for `unavailable` only, optional: the build define the host left out (`MPX_LIBRARY_SAVE`, or `MPX_LIBRARY_PHOTOS` for an album) |
///
/// One map for Android and Apple: the native side decides which grant a
/// destination needs (none on Android 29 and later, the legacy write
/// permission below, add-only or read and write on Apple), so the Dart
/// side never repeats the platform's version rules.
///
/// ## Decoding
///
/// Strict: a missing or unknown `scope` or `status`, or a `missing` that is
/// not a string, throws a [FormatException] whose message names the field.
/// Unknown keys are ignored.
final class SaveAccessCodec
    extends Codec<SaveAccessAnswer, Map<Object?, Object?>> {
  /// The codec.
  const SaveAccessCodec();

  @override
  Converter<SaveAccessAnswer, Map<Object?, Object?>> get encoder =>
      const _Encoder();

  @override
  Converter<Map<Object?, Object?>, SaveAccessAnswer> get decoder =>
      const _Decoder();
}

abstract final class _Key {
  static const String scope = 'scope';
  static const String status = 'status';
  static const String missing = 'missing';
}

/// The wire's status names; `authorized` is [SaveAccess.granted], every
/// other is the state's own name.
abstract final class _Status {
  static const String authorized = 'authorized';

  static String of(SaveAccess access) => switch (access) {
    SaveAccess.granted => authorized,
    SaveAccess.notDetermined ||
    SaveAccess.denied ||
    SaveAccess.restricted ||
    SaveAccess.limited ||
    SaveAccess.unavailable => access.name,
  };

  static SaveAccess? read(String name) => switch (name) {
    authorized => SaveAccess.granted,
    // `granted` is spelled `authorized` on the wire.
    'granted' => null,
    _ => SaveAccess.values.asNameMap()[name],
  };
}

final class _Encoder
    extends Converter<SaveAccessAnswer, Map<Object?, Object?>> {
  const _Encoder();

  @override
  Map<Object?, Object?> convert(SaveAccessAnswer input) => {
    _Key.scope: input.scope.name,
    _Key.status: _Status.of(input.access),
    _Key.missing: ?input.missing,
  };
}

final class _Decoder
    extends Converter<Map<Object?, Object?>, SaveAccessAnswer> {
  const _Decoder();

  @override
  SaveAccessAnswer convert(Map<Object?, Object?> input) {
    final scope = SaveAccessScope.values
        .asNameMap()[_string(input, _Key.scope)];
    if (scope == null) throw FormatException(_Key.scope, input);
    final access = _Status.read(_string(input, _Key.status));
    if (access == null) throw FormatException(_Key.status, input);
    final missing = switch (input[_Key.missing]) {
      null => null,
      final String define => define,
      _ => throw FormatException(_Key.missing, input),
    };
    return SaveAccessAnswer(access, scope: scope, missing: missing);
  }

  static String _string(Map<Object?, Object?> input, String key) =>
      switch (input[key]) {
        final String value => value,
        _ => throw FormatException(key, input),
      };
}
