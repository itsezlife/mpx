// The part of the public API that needs `dart:ffi`. The barrel exports this
// file by default and swaps in `native_exports_js.dart` where
// `dart.library.js_interop` is true (the web), so a web build never reaches an
// FFI import.
export 'package:mpx_video_decoder/src/binding/ffi/native_video_binding.dart';
export 'package:mpx_video_decoder/src/binding/video_binding.dart';
