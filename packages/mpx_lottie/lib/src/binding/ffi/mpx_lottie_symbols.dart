// The C ABI of native/include/mpx_lottie.h, bound by hand: eight functions
// are too few to be worth putting LLVM (ffigen) on every contributor. The
// asset id of these `@Native`s is this file's library URI, which is the name
// hook/build.dart registers the library under; moving this file means
// changing `_assetName` there.
// The names mirror the header one to one and are documented there.
// ignore_for_file: public_member_api_docs
import 'dart:ffi';

/// The ABI of `mpx_lottie.h` the bindings were written against.
abstract final class MpxLottieAbi {
  /// The version a library must answer from its ABI probe.
  static const expectedVersion = 1;
}

/// The status numbers of `mpx_lottie.h`, in one place so no other file
/// carries a bare literal.
abstract final class MpxLottieStatus {
  static const ok = 0;
  static const invalidArgument = -1;
  static const tooLarge = -2;
  static const malformed = -3;
  static const limitExceeded = -4;
  static const unsupported = -5;
  static const internal = -6;
  static const badSize = -7;
  static const renderFailed = -8;
}

/// `MpxLottieInfo`.
final class MpxLottieInfo extends Struct {
  @Uint32()
  external int width;

  @Uint32()
  external int height;

  @Uint32()
  external int frameCount;

  @Float()
  external double frameRate;

  @Uint32()
  external int features;
}

/// `MpxLottieJob`.
final class MpxLottieJob extends Struct {
  external Pointer<Void> handle;

  @Float()
  external double frame;

  @Uint32()
  external int width;

  @Uint32()
  external int height;

  external Pointer<Uint8> target;

  @Size()
  external int strideBytes;
}

/// The load probe: returns 1. A leaf: it is instant.
@Native<Uint32 Function()>(isLeaf: true, symbol: 'mpx_lottie_abi_version')
external int mpxLottieAbiVersion();

/// Not a leaf: parsing and inflating run long enough to stall the isolate
/// group at a safepoint.
@Native<
  Int32 Function(
    Pointer<Uint8>,
    Size,
    Pointer<MpxLottieInfo>,
    Pointer<Pointer<Void>>,
  )
>(symbol: 'mpx_lottie_load')
external int mpxLottieLoad(
  Pointer<Uint8> data,
  int len,
  Pointer<MpxLottieInfo> outInfo,
  Pointer<Pointer<Void>> outHandle,
);

/// A leaf: it only drops memory.
@Native<Void Function(Pointer<Void>)>(isLeaf: true, symbol: 'mpx_lottie_free')
external void mpxLottieFree(Pointer<Void> handle);

/// Not a leaf: a batch of draws is long.
@Native<Int32 Function(Pointer<MpxLottieJob>, Size, Pointer<Int32>)>(
  symbol: 'mpx_lottie_render_batch',
)
external int mpxLottieRenderBatch(
  Pointer<MpxLottieJob> jobs,
  int count,
  Pointer<Int32> statuses,
);

/// The worst-case compressed size of a region, 0 for a size the codec
/// refuses. Not a leaf, like the other two codec calls: they run long enough
/// to stall the isolate group at a safepoint.
@Native<Size Function(Uint32, Uint32)>(symbol: 'mpx_lottie_lz4_bound')
external int mpxLottieLz4Bound(int width, int height);

@Native<
  Int32 Function(
    Pointer<Uint8>,
    Size,
    Uint32,
    Uint32,
    Pointer<Uint8>,
    Size,
    Pointer<Size>,
  )
>(symbol: 'mpx_lottie_compress_region')
external int mpxLottieCompressRegion(
  Pointer<Uint8> target,
  int strideBytes,
  int width,
  int height,
  Pointer<Uint8> dst,
  int dstCap,
  Pointer<Size> outLen,
);

@Native<
  Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size, Uint32, Uint32)
>(symbol: 'mpx_lottie_decompress_region')
external int mpxLottieDecompressRegion(
  Pointer<Uint8> src,
  int srcLen,
  Pointer<Uint8> target,
  int strideBytes,
  int width,
  int height,
);
