// The C ABI of native/include/mpx_video.h, bound by hand: nine functions are
// too few to be worth putting LLVM (ffigen) on every contributor. The asset
// id of these `@Native`s is this file's library URI, which is the name
// hook/build.dart registers the library under; moving this file means
// changing `mpxVideoAssetName` there.
// The names mirror the header one to one and are documented there.
// ignore_for_file: public_member_api_docs
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The ABI of `mpx_video.h` the bindings were written against.
abstract final class MpxVideoAbi {
  /// The version a library must answer from its ABI probe.
  static const expectedVersion = 3;

  /// The version of the ranged reader table `mpx_video_open_reader` reads.
  static const readerVersion = 3;
}

/// The status numbers of `mpx_video.h`, in one place so no other file
/// carries a bare literal. A test compares them with the header.
abstract final class MpxVideoStatus {
  static const stalled = 2;
  static const endOfStream = 1;
  static const ok = 0;
  static const invalidArgument = -1;
  static const tooLarge = -2;
  static const malformed = -3;
  static const limitExceeded = -4;
  static const unsupported = -5;
  static const internal = -6;
  static const badSize = -7;
  static const decodeFailed = -8;
  static const sourceFailed = -9;
}

/// `MpxVideoInfo`.
final class MpxVideoInfo extends Struct {
  @Uint32()
  external int width;

  @Uint32()
  external int height;

  @Int64()
  external int durationMs;

  @Float()
  external double frameRate;

  @Uint32()
  external int hasAlpha;
}

/// The load probe: returns 1. A leaf: it is instant.
@Native<Uint32 Function()>(isLeaf: true, symbol: 'mpx_video_abi_version')
external int mpxVideoAbiVersion();

/// Not a leaf: probing a container and opening a decoder run long enough to
/// stall the isolate group at a safepoint.
@Native<
  Int32 Function(Pointer<Uint8>, Size, Uint32, Uint32, Pointer<Pointer<Void>>)
>(symbol: 'mpx_video_open')
external int mpxVideoOpen(
  Pointer<Uint8> data,
  int len,
  int targetW,
  int targetH,
  Pointer<Pointer<Void>> outHandle,
);

/// Not a leaf: it opens the file and probes the container like
/// [mpxVideoOpen].
@Native<Int32 Function(Pointer<Utf8>, Uint32, Uint32, Pointer<Pointer<Void>>)>(
  symbol: 'mpx_video_open_file',
)
external int mpxVideoOpenFile(
  Pointer<Utf8> path,
  int targetW,
  int targetH,
  Pointer<Pointer<Void>> outHandle,
);

/// Not a leaf: it probes the container, from the bytes that have landed.
@Native<
  Int32 Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Int64,
    Uint32,
    Uint32,
    Pointer<Pointer<Void>>,
  )
>(symbol: 'mpx_video_open_reader')
external int mpxVideoOpenReader(
  Pointer<Void> readerApi,
  Pointer<Utf8> key,
  int lookahead,
  int targetW,
  int targetH,
  Pointer<Pointer<Void>> outHandle,
);

/// A leaf: it only copies a few fields.
@Native<Int32 Function(Pointer<Void>, Pointer<MpxVideoInfo>)>(
  isLeaf: true,
  symbol: 'mpx_video_info',
)
external int mpxVideoInfo(Pointer<Void> handle, Pointer<MpxVideoInfo> out);

/// Not a leaf: a decode and a scale are long.
@Native<Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Int64>)>(
  symbol: 'mpx_video_next',
)
external int mpxVideoNext(
  Pointer<Void> handle,
  Pointer<Uint8> dst,
  int stride,
  Pointer<Int64> outPtsMs,
);

/// Not a leaf: a seek reads the container.
@Native<Int32 Function(Pointer<Void>)>(symbol: 'mpx_video_rewind')
external int mpxVideoRewind(Pointer<Void> handle);

/// Not a leaf: a seek reads the container.
@Native<Int32 Function(Pointer<Void>, Int64)>(symbol: 'mpx_video_seek')
external int mpxVideoSeek(Pointer<Void> handle, int positionMs);

/// Not a leaf: closing a decoder joins its threads.
@Native<Void Function(Pointer<Void>)>(symbol: 'mpx_video_free')
external void mpxVideoFree(Pointer<Void> handle);
