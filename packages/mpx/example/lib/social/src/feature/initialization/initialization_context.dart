import 'package:http_bytes_cache/native_reader.dart';

/// Transient objects used only while composing `Dependencies`.
///
/// What a later step needs from an earlier one but the running app does not:
/// the native reader the stack's publisher builds is read once more, by the
/// players, and by nothing after them.
final class InitializationContext {
  /// Creates an empty initialization scratch pad.
  InitializationContext();

  /// The process's one native reader over the stack's ranged resources, or
  /// null where the build has none (the stack's publisher builds it).
  NativeRangedReaders? readers;
}
