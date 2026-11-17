import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// A ranged reader over plain files (`fake_ranged_reader.c` next to this
/// file), compiled for this machine: the reader table a ranged source opens,
/// with the test deciding how many bytes of each resource have landed.
///
/// The technique of the texture table: the decoder never depends on the
/// bytes cache, so its tests bring a reader of their own.
final class RangedReaderTable {
  RangedReaderTable._(this.libraryPath)
    : _library = DynamicLibrary.open(libraryPath);

  /// Opens the table compiled at [libraryPath] (one process loads it once,
  /// so every isolate sees the same resources).
  factory RangedReaderTable.at(String libraryPath) =>
      RangedReaderTable._(libraryPath);

  /// Compiles the table once per test process, or answers null with the
  /// reason in [skipReason] when this machine has no C compiler.
  static RangedReaderTable? compile() => _compiled ??= _compile();
  static RangedReaderTable? _compiled;

  /// Why [compile] answered null, for a skip message.
  static String skipReason = '';

  static RangedReaderTable? _compile() {
    final source = _source();
    final out = Directory.systemTemp.createTempSync('fake_ranged_reader');
    final library =
        '${out.path}/libfake_ranged_reader'
        '${Platform.isMacOS ? '.dylib' : '.so'}';
    final ProcessResult result;
    try {
      result = Process.runSync('cc', [
        '-shared',
        '-fPIC',
        '-std=c11',
        '-Wall',
        '-Werror',
        '-fvisibility=hidden',
        source,
        '-o',
        library,
        '-lpthread',
      ]);
    } on ProcessException catch (error) {
      skipReason = 'no C compiler (cc) here: $error';
      return null;
    }
    if (result.exitCode != 0) {
      fail('compiling the fake ranged reader failed:\n${result.stderr}');
    }
    return RangedReaderTable._(library);
  }

  static String _source() {
    const relative = 'test/native/support/fake_ranged_reader.c';
    for (final base in [
      Directory.current.path,
      '${Directory.current.path}/packages/mpx_video_decoder',
    ]) {
      if (File('$base/$relative').existsSync()) return '$base/$relative';
    }
    throw StateError('$relative not found from ${Directory.current.path}');
  }

  /// Where the compiled table is, for another isolate to open it.
  final String libraryPath;

  final DynamicLibrary _library;

  /// Address of the reader table (version 2).
  int get api => _library
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'fake_reader_api',
      )()
      .address;

  /// Address of a table that claims version 2 (no `reader_available`).
  int get oldApi => _library
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'fake_reader_api_v1',
      )()
      .address;

  /// Publishes the file at [path] as [key], its first [landed] bytes present
  /// (all of them by default) and its length told unless [lengthKnown] is
  /// false.
  void publish(
    String key,
    String path, {
    int? landed,
    bool lengthKnown = true,
  }) {
    final status = using(
      (arena) =>
          _library.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int64, Int32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int, int)
          >('fake_reader_publish')(
            key.toNativeUtf8(allocator: arena),
            path.toNativeUtf8(allocator: arena),
            landed ?? 1 << 40,
            lengthKnown ? 1 : 0,
          ),
    );
    if (status != 0) throw StateError('could not publish $path as $key');
  }

  /// Bytes `[0, landed)` of [key] are present, and its length is known.
  void land(String key, int landed) => using(
    (arena) =>
        _library.lookupFunction<
          Void Function(Pointer<Utf8>, Int64),
          void Function(Pointer<Utf8>, int)
        >('fake_reader_land')(key.toNativeUtf8(allocator: arena), landed),
  );

  /// Bytes `[start, end)` of [key] are present too, its length known.
  void landSpan(String key, int start, int end) => using(
    (arena) =>
        _library.lookupFunction<
          Void Function(Pointer<Utf8>, Int64, Int64),
          void Function(Pointer<Utf8>, int, int)
        >('fake_reader_land_span')(
          key.toNativeUtf8(allocator: arena),
          start,
          end,
        ),
  );

  /// How many times a decoder found bytes of [key] missing and asked.
  int askedOf(String key) => _stat('fake_reader_asked', key);

  /// Withdraws [key]: blocked and later reads fail.
  void withdraw(String key) => using(
    (arena) =>
        _library.lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('fake_reader_withdraw')(key.toNativeUtf8(allocator: arena)),
  );

  int _stat(String name, String key) => using(
    (arena) =>
        _library.lookupFunction<
          Int64 Function(Pointer<Utf8>),
          int Function(Pointer<Utf8>)
        >(name)(key.toNativeUtf8(allocator: arena)),
  );

  /// How many reads of [key] blocked for bytes (or its length).
  int waitsOf(String key) => _stat('fake_reader_waits', key);

  /// How many readers of [key] were opened.
  int opensOf(String key) => _stat('fake_reader_opens', key);

  /// How many readers of [key] are open now.
  int openReadersOf(String key) => _stat('fake_reader_open_readers', key);
}
