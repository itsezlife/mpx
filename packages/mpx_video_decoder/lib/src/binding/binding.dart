/// The binding interface to the native video decoder.
///
/// The value types (handle, info, open result, frame result, availability)
/// compile everywhere. The bindings use `dart:ffi` and are exported only where
/// it exists.
library;

// The VM half is the default and the JS half the exception: the analyzer
// resolves a conditional export to its default URI, so the default must be
// the file that holds the bindings. `dart.library.js_interop` is true on every
// web compiler (dart2js and dart2wasm) and false on the VM.
export 'native_exports_vm.dart'
    if (dart.library.js_interop) 'native_exports_js.dart';
export 'video_availability.dart';
export 'video_frame_result.dart';
export 'video_handle.dart';
export 'video_open_result.dart';
export 'video_source.dart';
