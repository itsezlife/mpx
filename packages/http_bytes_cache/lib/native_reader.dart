/// The native reader of ranged resources, for hosts on the Dart VM.
///
/// [NativeRangedReaders] publishes [RangedResource]s to a C library this
/// package builds with its build hook, so native players read the cached
/// sparse files directly and block only on missing bytes. Imports `dart:ffi`:
/// web code must not import this library.
library;

import 'package:http_bytes_cache/http_bytes_cache.dart';

export 'src/native/native_ranged_readers.dart';
