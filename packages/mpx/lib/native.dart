/// The parts of mpx that need the bytes cache's native reader, for hosts on
/// the Dart VM. Imports `dart:ffi` through it: web code must not import this
/// library.
library;

export 'src/native/native_ranged_content_publisher.dart';
