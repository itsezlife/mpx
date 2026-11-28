import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:mpx_core/mpx_core.dart';

/// A file copy for a save, streamed on a worker isolate so neither the
/// bytes nor the loop over them reach the UI isolate.
///
/// The worker reads and writes one chunk at a time and tells each chunk's
/// progress; a cancel reaches it between chunks. Asynchronous `dart:io`
/// alone would already do the reads off the UI thread, but every chunk
/// would still pass through the UI isolate's heap; a video is too large for
/// that (ADR 0011, *Copy*).
abstract final class SaveFileCopy {
  /// The chunk read and written at a time: large enough that the messages
  /// per chunk cost nothing beside the I/O, small enough that a cancel
  /// lands at once.
  static const int defaultChunkSize = 1 << 20;

  /// Copies [from] into [to] (created or truncated), telling the bytes
  /// written through [onProgress]. True once copied; false when
  /// [cancellation] stopped it, leaving [to] partial for the caller to
  /// remove. A file system failure is rethrown here as the worker met it.
  static Future<bool> run(
    String from,
    String to, {
    required FetchProgress onProgress,
    required CancellationToken cancellation,
    int chunkSize = defaultChunkSize,
  }) async {
    final inbox = ReceivePort();
    final done = Completer<bool>();
    SendPort? control;
    var cancelled = false;
    cancellation.onCancel(() {
      cancelled = true;
      control?.send(null);
    });
    inbox.listen((message) {
      if (done.isCompleted) return;
      switch (message) {
        case final SendPort port:
          control = port;
          // A cancel before the worker could hear it.
          if (cancelled) port.send(null);
        case _CopyProgress(:final written, :final total):
          onProgress(written, total);
        case _CopyEnd(:final copied):
          done.complete(copied);
        case _CopyFailure(:final error):
          done.completeError(error);
        // The worker's uncaught error ([error, stack] as strings), or its
        // exit before an end.
        case [final Object? error, final Object? stack]:
          done.completeError(
            StateError('the copy worker failed: $error'),
            StackTrace.fromString('$stack'),
          );
        case null:
          done.completeError(StateError('the copy worker exited'));
      }
    });
    try {
      await Isolate.spawn(
        _$copy,
        _CopyRequest(inbox.sendPort, from, to, chunkSize),
        onError: inbox.sendPort,
        onExit: inbox.sendPort,
        debugName: 'mpx_library save copy',
      );
      return await done.future;
    } finally {
      inbox.close();
    }
  }
}

// --- The worker and its messages ---

final class _CopyRequest {
  const _CopyRequest(this.reply, this.from, this.to, this.chunkSize);

  final SendPort reply;
  final String from;
  final String to;
  final int chunkSize;
}

final class _CopyProgress {
  const _CopyProgress(this.written, this.total);

  final int written;
  final int total;
}

final class _CopyEnd {
  const _CopyEnd({required this.copied});

  final bool copied;
}

final class _CopyFailure {
  const _CopyFailure(this.error);

  final FileSystemException error;
}

/// The worker: its control port first, then a progress per chunk, then an
/// end or a failure. Each `await` lets a cancel message in.
Future<void> _$copy(_CopyRequest request) async {
  final control = ReceivePort();
  var cancelled = false;
  control.listen((_) => cancelled = true);
  request.reply.send(control.sendPort);
  RandomAccessFile? input;
  RandomAccessFile? output;
  try {
    input = await File(request.from).open();
    final total = await input.length();
    output = await File(request.to).open(mode: FileMode.writeOnly);
    var written = 0;
    while (!cancelled) {
      final chunk = await input.read(request.chunkSize);
      if (chunk.isEmpty) break;
      await output.writeFrom(chunk);
      written += chunk.length;
      request.reply.send(_CopyProgress(written, total));
    }
    if (!cancelled) await output.flush();
    request.reply.send(_CopyEnd(copied: !cancelled));
  } on FileSystemException catch (error) {
    request.reply.send(_CopyFailure(error));
  } finally {
    await input?.close();
    await output?.close();
    control.close();
  }
}
