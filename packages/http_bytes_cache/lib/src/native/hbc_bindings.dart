/// FFI bindings of the native reader (`native/include/http_bytes_cache.h`).
///
/// The code asset is built by `hook/build.dart` under this library's URI.
@DefaultAsset('package:http_bytes_cache/src/native/hbc_bindings.dart')
library;

import 'dart:ffi';

/// `hbc_fetch_fn`: asks the Dart side to fetch bytes of a resource.
typedef HbcFetchNative =
    Void Function(Int64 resourceId, Int64 offset, Int64 length, Int32 priority);

/// The opaque `hbc_reader`.
final class HbcReader extends Opaque {}

@Native<Int32 Function()>(symbol: 'hbc_abi_version')
external int hbcAbiVersion();

/// `HBC_ERR_BUSY`: [hbcAttach] found another host attached.
const int hbcErrBusy = -5;

@Native<Int64 Function(Pointer<NativeFunction<HbcFetchNative>>)>(
  symbol: 'hbc_attach',
)
external int hbcAttach(Pointer<NativeFunction<HbcFetchNative>> fetch);

@Native<Void Function(Int64)>(symbol: 'hbc_detach')
external void hbcDetach(int owner);

@Native<Void Function(Pointer<Void>)>(symbol: 'hbc_detach_finalizer')
external void hbcDetachFinalizer(Pointer<Void> owner);

@Native<Int64 Function(Pointer<Char>, Pointer<Char>, Int64)>(
  symbol: 'hbc_publish',
)
external int hbcPublish(Pointer<Char> key, Pointer<Char> path, int total);

@Native<Void Function(Int64, Int64)>(symbol: 'hbc_set_length')
external void hbcSetLength(int id, int total);

@Native<Void Function(Int64, Int64, Int64)>(symbol: 'hbc_range_landed')
external void hbcRangeLanded(int id, int start, int end);

@Native<Void Function(Int64)>(symbol: 'hbc_ranges_reset')
external void hbcRangesReset(int id);

@Native<Void Function(Int64, Int64, Int64)>(symbol: 'hbc_fetch_failed')
external void hbcFetchFailed(int id, int offset, int length);

@Native<Void Function(Int64)>(symbol: 'hbc_unpublish')
external void hbcUnpublish(int id);

@Native<Pointer<HbcReader> Function(Pointer<Char>)>(symbol: 'hbc_reader_open')
external Pointer<HbcReader> hbcReaderOpen(Pointer<Char> key);

@Native<Int64 Function(Pointer<HbcReader>, Int32)>(
  symbol: 'hbc_reader_length',
)
external int hbcReaderLength(Pointer<HbcReader> reader, int wait);

@Native<Int64 Function(Pointer<HbcReader>, Int64, Pointer<Uint8>, Int64)>(
  symbol: 'hbc_reader_read',
)
external int hbcReaderRead(
  Pointer<HbcReader> reader,
  int offset,
  Pointer<Uint8> buffer,
  int length,
);

@Native<Void Function(Pointer<HbcReader>, Int32)>(
  symbol: 'hbc_reader_set_priority',
)
external void hbcReaderSetPriority(Pointer<HbcReader> reader, int priority);

@Native<Void Function(Pointer<HbcReader>)>(symbol: 'hbc_reader_cancel')
external void hbcReaderCancel(Pointer<HbcReader> reader);

@Native<Int64 Function(Pointer<HbcReader>, Int64, Int64)>(
  symbol: 'hbc_reader_available',
)
external int hbcReaderAvailable(
  Pointer<HbcReader> reader,
  int offset,
  int length,
);

@Native<Void Function(Pointer<HbcReader>)>(symbol: 'hbc_reader_close')
external void hbcReaderClose(Pointer<HbcReader> reader);

@Native<Pointer<Void> Function()>(symbol: 'hbc_get_api')
external Pointer<Void> hbcGetApi();
