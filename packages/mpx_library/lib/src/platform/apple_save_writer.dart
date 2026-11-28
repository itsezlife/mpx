import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/platform/save_block_codec.dart';
import 'package:mpx_library/src/save/save_error_summary.dart';
import 'package:mpx_library/src/save/save_op.dart';
import 'package:mpx_library/src/save/save_result.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The save writer of Apple: one native `saveBlock` call per batch
/// ([SaveBlockRequestCodec] / [SaveBlockAnswerCodec] are the wire).
///
/// - `gallery`: one Photos change block for the whole batch, so one prompt
///   and one atomic result; each asset gets the item's name, type and
///   creation date. A GIF animation is saved as an animated image, a video
///   one as a video. A named album is added in the same block, or skipped
///   under limited access, which cannot fetch or make one.
/// - `downloads` (iOS): the app's Documents, in the host's sub-folder, which
///   the system's file browser shows when the host declares
///   `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`;
///   without them the batch goes to the export picker, as `ask`. A taken
///   name becomes `name (1)`. The batch is atomic here too: a failed copy
///   removes the copies made before it.
/// - `ask` (iOS): the system's export picker over the whole batch; a
///   dismissed picker cancels every item.
///
/// On macOS (`MacosSaveWriter`) only the gallery is a block of this
/// writer; Downloads and `ask` are files the Dart side writes.
///
/// The native side reads files, so an item held in memory
/// (`SaveItem.bytes`) is first written to a temporary file under its name,
/// removed once the block ends.
///
/// A cancel counts only before the block begins (the runner holds that
/// rule). The native side reports a failure as the platform error it got;
/// [failureOf] maps it.
final class AppleSaveWriter extends SaveWriter$Block {
  /// The writer over [_methods], reporting itself as [platform].
  const AppleSaveWriter(this._methods, {this.platform = 'ios'});

  final MethodChannel _methods;

  @override
  final String platform;

  static const _requests = SaveBlockRequestCodec();
  static const _answers = SaveBlockAnswerCodec();

  @override
  Future<List<SaveResult>> writeBlock(
    List<SaveWrite> writes, {
    required void Function(double fraction) onProgress,
  }) async {
    final first = writes.first;
    // The native side reads files: an item held in memory is written to a
    // temporary file first, under its own name (Photos and Files name the
    // saved item after its file), and the folder goes once the block ends.
    Directory? spill;
    try {
      final paths = <String>[];
      for (final (index, write) in writes.indexed) {
        if (write.item.bytes case final bytes?) {
          spill ??= await Directory.systemTemp.createTemp('mpx_library_save_');
          final folder = await Directory(
            '${spill.path}${Platform.pathSeparator}$index',
          ).create();
          final file = File(
            '${folder.path}${Platform.pathSeparator}'
            '${DesktopSaveNames.sanitize(write.item.name)}',
          );
          await file.writeAsBytes(bytes, flush: true);
          paths.add(file.path);
        } else {
          paths.add(write.item.path!);
        }
      }
      return await _block(first, writes, paths);
    } finally {
      if (spill != null) await _remove(spill);
    }
  }

  Future<List<SaveResult>> _block(
    SaveWrite first,
    List<SaveWrite> writes,
    List<String> paths,
  ) async {
    final map = await _methods.invokeMapMethod<Object?, Object?>(
      'saveBlock',
      _requests.encode(
        SaveBlockRequest(
          destination: first.destination,
          entries: [
            for (final (index, write) in writes.indexed)
              SaveBlockEntry(
                path: paths[index],
                name: write.item.name,
                mimeType: write.item.mimeType,
                kind: write.kind,
                createdAt: write.item.createdAt,
                move: write.move,
              ),
          ],
        ),
      ),
    );
    if (map == null) throw const FormatException('no answer to saveBlock');
    final answer = _answers.decode(map);
    _report(first.jobId, answer);
    return switch (answer) {
      SaveBlockAnswer$Saved(:final items) =>
        items.length == writes.length
            ? [
                for (final item in items)
                  SaveResult.saved(item.ref, renamed: item.renamed),
              ]
            : throw FormatException(
                'items',
                '${items.length} for ${writes.length}',
              ),
      SaveBlockAnswer$Failed(:final domain, :final code) => List.filled(
        writes.length,
        SaveResult.failed(failureOf(domain, code), code: '$domain.$code'),
      ),
      SaveBlockAnswer$Cancelled() => List.filled(
        writes.length,
        const SaveResult.cancelled(),
      ),
    };
  }

  /// The [SaveFailure] of the platform error [code] in [domain]: Photos'
  /// `PHPhotosError` codes, Foundation's file error codes, POSIX errno
  /// values, or the plugin's own (always [SaveFailure.unavailable]).
  static SaveFailure failureOf(String domain, String code) =>
      switch ((domain, int.tryParse(code))) {
        // accessRestricted, accessUserDenied.
        ('photos', 3310 || 3311) => SaveFailure.accessDenied,
        ('photos', 3305) => SaveFailure.noSpace,
        // invalidResource: Photos does not take the file's format.
        ('photos', 3302) => SaveFailure.unsupportedFormat,
        // NSFileReadNoPermissionError, NSFileWriteNoPermissionError.
        ('cocoa', 257 || 513) => SaveFailure.accessDenied,
        // NSFileWriteOutOfSpaceError.
        ('cocoa', 640) => SaveFailure.noSpace,
        // EPERM, EACCES.
        ('posix', 1 || 13) => SaveFailure.accessDenied,
        // ENOSPC, EDQUOT.
        ('posix', 28 || 69) => SaveFailure.noSpace,
        _ => SaveFailure.unavailable,
      };

  /// Removes the temporary folder of a block's in-memory items. One that
  /// will not go is reported (by its error's type and code, never the
  /// path) and left to the system, which clears its temporary files.
  static Future<void> _remove(Directory spill) async {
    try {
      await spill.delete(recursive: true);
    } on FileSystemException catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: SaveErrorSummary.of(
            error,
            code: 'os${error.osError?.errorCode}',
          ),
          stack: stackTrace,
          library: 'mpx_library',
          context: ErrorDescription(
            'while removing a saved item\'s temporary file',
          ),
        ),
      );
    }
  }

  static void _report(String jobId, SaveBlockAnswer answer) {
    if (answer.fallback case final fallback?) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.debug,
        SaveOp.fallbackToAsk,
        jobId: jobId,
        fields: () => {'why': fallback.name},
      );
    }
    if (answer case SaveBlockAnswer$Saved(album: SaveBlockAlbum.skipped)) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.debug,
        SaveOp.albumSkipped,
        jobId: jobId,
        fields: () => {'why': 'limited'},
      );
    }
  }
}
