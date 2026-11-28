import 'package:flutter/services.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/platform/android_save_wire.dart';
import 'package:mpx_library/src/platform/platform_save_access.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_result.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The save writer of Android, over the plugin's native saver
/// (`android_save_wire.dart` is the wire).
///
/// - API 29 and later: a MediaStore row (`Images` or `Video` under
///   `Pictures/<album>` / `Movies/<album>`, `Downloads` under
///   `Download/<subfolder>`) inserted pending, the bytes streamed into it,
///   then published; the store renames a taken name. Other apps see nothing
///   until it is published.
/// - API 28 and below: a hidden file in the public picture, movie or
///   download directory, renamed into place (`name(1)` to `name(10)` when
///   taken) and handed to the media scanner.
/// - `ask`: the system's create-document dialog, one per item; a dismissed
///   dialog cancels the batch, its item and every one after it.
///
/// The copy runs on the native side off the main thread, a few MiB per
/// `saveStep` call, so the Dart side reports progress after each step and
/// stops between them on a cancel; an aborted or failed write leaves no
/// pending row or file. Platform errors come back as short codes and are
/// mapped to a [SaveFailure] here, the code kept for diagnostics.
final class AndroidSaveWriter extends SaveWriter$PerItem {
  /// The writer over [methods], admitting a batch through [access].
  const AndroidSaveWriter(this._methods, {required this.access});

  final MethodChannel _methods;

  /// The save access (the legacy write permission on API 28 and below).
  final PlatformSaveAccess access;

  static const _start = AndroidSaveStartCodec();
  static const _step = AndroidSaveStepCodec();

  @override
  String get platform => 'android';

  @override
  Future<SaveResult$Failed?> admit(
    String jobId,
    SaveDestination destination,
    List<SaveItem> items,
  ) => access.admit(jobId, destination);

  @override
  Future<SaveResult> write(
    SaveWrite write, {
    required FetchProgress onProgress,
    required CancellationToken cancellation,
  }) async {
    int? id;
    var published = false;
    try {
      id = await _methods.invokeMethod<int>(
        'saveBegin',
        _start.encode(_startOf(write)),
      );
      if (id == null) {
        // The user said no to the batch, not to one item: the job's cancel
        // ends this item and stops the ones after it unasked.
        cancellation.cancel();
        return const SaveResult.cancelled();
      }
      while (!cancellation.isCancelled) {
        final answer = await _methods.invokeMapMethod<Object?, Object?>(
          'saveStep',
          {'write': id},
        );
        final step = _step.decode(
          answer ?? (throw const FormatException('no answer to saveStep')),
        );
        onProgress(step.written, step.total);
        if (step case AndroidSaveStep$Done(:final ref, :final renamed)) {
          published = true;
          return SaveResult.saved(ref, renamed: renamed);
        }
      }
      return const SaveResult.cancelled();
    } on PlatformException catch (error) {
      // The message can hold a path or a URI: only the code goes on.
      return SaveResult.failed(_reasonOf(error.code), code: error.code);
    } finally {
      // A cancel, a failed step (already discarded natively) or a bad
      // answer: the pending row goes, so nothing half-written stays.
      if (id != null && !published) {
        await _methods.invokeMethod<void>('saveAbort', {'write': id});
      }
    }
  }

  static AndroidSaveStart _startOf(SaveWrite write) {
    final item = write.item;
    return AndroidSaveStart(
      destination: write.destination.name,
      folder: switch (write.destination) {
        SaveDestination$Gallery(:final album) => album,
        SaveDestination$Downloads(:final subfolder) => subfolder,
        SaveDestination$Ask() => null,
      },
      name: item.name,
      mimeType: item.mimeType,
      kind: write.kind,
      createdAt: item.createdAt,
      path: item.path,
      bytes: item.bytes,
      move: write.move,
    );
  }

  /// The [SaveFailure] a native error code means.
  static SaveFailure _reasonOf(String code) => switch (code) {
    'ENOSPC' => SaveFailure.noSpace,
    // The store refused the MIME type for the collection.
    'mimeRejected' => SaveFailure.unsupportedFormat,
    'security' => SaveFailure.accessDenied,
    // `sourceMissing`, `insertFailed`, `nameTaken`, `noActivity`, `failed`.
    _ => SaveFailure.unavailable,
  };
}
