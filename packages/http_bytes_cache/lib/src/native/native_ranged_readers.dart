import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http_bytes_cache/src/bytes_cache.dart';
import 'package:http_bytes_cache/src/bytes_diagnostics.dart';
import 'package:http_bytes_cache/src/http/byte_range.dart';
import 'package:http_bytes_cache/src/http/request_priority.dart';
import 'package:http_bytes_cache/src/native/hbc_bindings.dart';
import 'package:http_bytes_cache/src/ranged/ranged_bytes.dart';

/// The Dart side of the native reader: publishes ranged resources to it,
/// fetches what its readers miss, and signals every landing over FFI.
///
/// Native players open a reader by cache key ([BytesCacheKey.value]) through
/// the C interface in `native/include/http_bytes_cache.h` (or the function
/// table at [apiAddress]). A read of present bytes reads the sparse file
/// directly; a read of missing bytes calls back here, which fetches at least
/// [readAheadBytes] from there at the reader's priority through
/// [RangedResource.ensure], while the reader blocks on its own thread until
/// the "range landed" signal wakes it. Only control messages cross into Dart.
///
/// One per process: the native side has a single fetch callback. Requires
/// the code asset the package's build hook compiles ([isAvailable]); VM
/// only.
final class NativeRangedReaders {
  /// Serves readers of [ranged]'s resources.
  ///
  /// Throws [StateError] when another instance is open in this isolate, and
  /// [UnsupportedError] when the native library is missing.
  NativeRangedReaders(this.ranged, {this.readAheadBytes = 512 * 1024}) {
    if (!isAvailable) {
      throw UnsupportedError(
        'The native reader of http_bytes_cache is not built for this target.',
      );
    }
    if (_active != null) {
      throw StateError('Another NativeRangedReaders is open');
    }
    _active = this;
    _fetch = NativeCallable<HbcFetchNative>.listener(_onFetch);
    hbcSetFetchCallback(_fetch.nativeFunction);
  }

  static NativeRangedReaders? _active;

  /// Whether the native library is loaded and speaks this interface.
  static bool get isAvailable {
    try {
      return hbcAbiVersion() == abiVersion;
    } on Object {
      // No code asset for this target (web builds never get here: this
      // library is VM only).
      return false;
    }
  }

  /// The C interface version this Dart side speaks (`HBC_ABI_VERSION`).
  static const int abiVersion = 1;

  /// Address of the native `hbc_api` function table, for a player's native
  /// code (Kotlin through JNI, Swift) to call the reader functions without
  /// linking this library by name.
  static int get apiAddress => hbcGetApi().address;

  /// The resources served.
  final RangedBytes ranged;

  /// Bytes fetched from a missing offset at least, so a reader moving
  /// forward finds the next bytes landed.
  final int readAheadBytes;

  late final NativeCallable<HbcFetchNative> _fetch;
  final Map<int, NativePublication> _byId = {};
  var _closed = false;

  /// Opens [request]'s ranged resource and makes it readable natively under
  /// its cache key. Close the publication to withdraw it: blocked readers
  /// then return `HBC_ERR_CLOSED`.
  Future<NativePublication> publish(RangedRequest request) async {
    if (_closed) throw StateError('NativeRangedReaders is closed');
    final resource = await ranged.open(request);
    final id = using((arena) {
      return hbcPublish(
        request.cacheKey.value.toNativeUtf8(allocator: arena).cast(),
        resource.path.toNativeUtf8(allocator: arena).cast(),
        resource.totalLength ?? -1,
      );
    });
    if (id == 0) {
      await resource.close();
      throw StateError(
        'The native reader could not publish ${request.cacheKey}',
      );
    }
    final publication = NativePublication._(this, id, resource);
    _byId[id] = publication;
    publication._start();
    return publication;
  }

  void _onFetch(int id, int offset, int length, int priority) {
    final publication = _byId[id];
    if (publication == null) return;
    final end = offset + (length > readAheadBytes ? length : readAheadBytes);
    final level =
        RequestPriority.values[priority.clamp(
          0,
          RequestPriority.values.length - 1,
        )];
    publication.resource
        .ensure(ByteRange(offset, end), priority: PriorityToken(level))
        .then(
          (_) => publication._pushLength(),
          onError: (Object error, StackTrace stackTrace) {
            if (publication._closed) return;
            hbcFetchFailed(id, offset, end - offset);
            BytesDiagnostics.current.report(
              BytesLogEvent(
                level: BytesLogLevel.warning,
                message:
                    'native reader: fetch of ${publication.resource.key} at '
                    '$offset failed: $error',
                op: BytesLogOp.nativeFetch,
                stackTrace: stackTrace,
              ),
            );
          },
        );
  }

  /// Withdraws every publication and detaches from the native side.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    hbcSetFetchCallback(nullptr);
    for (final publication in List.of(_byId.values)) {
      await publication.close();
    }
    _fetch.close();
    if (identical(_active, this)) _active = null;
  }
}

/// One ranged resource readable natively ([NativeRangedReaders.publish]).
final class NativePublication {
  NativePublication._(this._owner, this.id, this.resource);

  final NativeRangedReaders _owner;

  /// The native resource id.
  final int id;

  /// The shared ranged resource behind it.
  final RangedResource resource;

  StreamSubscription<RangedEvent>? _events;
  int? _length;
  var _closed = false;

  void _start() {
    _events = resource.events.listen((event) {
      if (_closed) return;
      switch (event) {
        case RangeLanded(:final range):
          _pushLength();
          hbcRangeLanded(id, range.start, range.end!);
        case RangesReset():
          hbcRangesReset(id);
          _pushLength();
      }
    });
    _pushLength();
    for (final (start, end) in resource.ranges.spans) {
      hbcRangeLanded(id, start, end);
    }
  }

  void _pushLength() {
    if (_closed) return;
    final total = resource.totalLength;
    if (total == null || total == _length) return;
    _length = total;
    hbcSetLength(id, total);
  }

  /// Withdraws the resource from native readers and closes its handle.
  /// Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _owner._byId.remove(id);
    hbcUnpublish(id);
    await _events?.cancel();
    await resource.close();
  }
}

/// A native reader driven from Dart: the same blocking reads a player makes.
///
/// [read] and [length] with `wait` block the calling thread until bytes land,
/// so call them on a helper isolate, never on one that also serves
/// [NativeRangedReaders] (it would wait on itself). [cancel] works from any
/// isolate through [address].
final class NativeRangedReader {
  NativeRangedReader._(this._reader);

  /// Opens a reader on the published [key], or null when it is not
  /// published.
  static NativeRangedReader? open(BytesCacheKey key) {
    final reader = using(
      (arena) => hbcReaderOpen(key.value.toNativeUtf8(allocator: arena).cast()),
    );
    return reader == nullptr ? null : NativeRangedReader._(reader);
  }

  /// Wakes the reads blocked on the reader at [address] ([address] of an
  /// open reader, possibly in another isolate).
  static void cancelAt(int address) =>
      hbcReaderCancel(Pointer<HbcReader>.fromAddress(address));

  final Pointer<HbcReader> _reader;

  /// Address of the native reader, for [cancelAt].
  int get address => _reader.address;

  /// The length, or -1 when unknown; with [wait], blocks until known. A
  /// negative result below -1 is an `HBC_ERR_*` code.
  int length({bool wait = false}) => hbcReaderLength(_reader, wait ? 1 : 0);

  /// Sets the priority missing bytes are fetched at.
  void setPriority(RequestPriority value) =>
      hbcReaderSetPriority(_reader, value.index);

  /// Reads up to [length] bytes at [offset], blocking while the first is
  /// missing. Empty at the end; throws [NativeReadException] on a negative
  /// result (cancelled, fetch failed, unpublished, IO).
  Uint8List read(int offset, int length) {
    final buffer = malloc<Uint8>(length);
    try {
      final count = hbcReaderRead(_reader, offset, buffer, length);
      if (count < 0) throw NativeReadException(count);
      return Uint8List.fromList(buffer.asTypedList(count));
    } finally {
      malloc.free(buffer);
    }
  }

  /// Wakes this reader's blocked reads with a cancel.
  void cancel() => hbcReaderCancel(_reader);

  /// Closes the reader; nothing may use it afterwards.
  void close() => hbcReaderClose(_reader);
}

/// A native read that ended without bytes.
final class NativeReadException implements Exception {
  /// The `HBC_ERR_*` [code].
  const NativeReadException(this.code);

  /// `-1` cancelled, `-2` fetch failed, `-3` unpublished, `-4` IO.
  final int code;

  /// Whether [NativeRangedReader.cancel] woke the read.
  bool get isCancelled => code == -1;

  @override
  String toString() => 'NativeReadException($code)';
}
