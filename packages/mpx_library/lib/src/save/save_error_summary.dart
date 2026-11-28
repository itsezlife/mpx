import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mpx_core/mpx_core.dart';

/// An error as the saver's diagnostics carry it: its type and, where it has
/// one, its short code; never its message.
///
/// The message of an error a save meets can hold user content: a
/// `FileSystemException` names the path, a `PlatformException` carries the
/// native text (a path, a URI), a codec's `FormatException` its source.
/// Events and error reports end up in logs users export (ADR 0013), so the
/// saver puts this in their place, never the error itself.
@immutable
final class SaveErrorSummary {
  /// The summary of [error]: its runtime type, and [code], or the code a
  /// `PlatformException` has.
  SaveErrorSummary.of(Object error, {String? code})
    : type = MpxEvent.clip('${error.runtimeType}'),
      code = switch ((code, error)) {
        (final String code, _) => MpxEvent.clip(code),
        (null, PlatformException(:final code)) => MpxEvent.clip(code),
        _ => null,
      };

  /// The error's type name.
  final String type;

  /// The error's short code, when it has one.
  final String? code;

  @override
  bool operator ==(Object other) =>
      other is SaveErrorSummary && other.type == type && other.code == code;

  @override
  int get hashCode => Object.hash(type, code);

  @override
  String toString() => code == null ? type : '$type($code)';
}
