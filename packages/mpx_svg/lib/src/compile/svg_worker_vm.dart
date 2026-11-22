import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:mpx_svg/src/compile/svg_compile_job.dart';
import 'package:mpx_svg/src/compile/svg_compiler.dart';
import 'package:mpx_svg/src/policy/svg_limits.dart';
import 'package:mpx_svg/src/policy/svg_sanitizer.dart';

/// A compile on an isolate of its own, ended on cancel or past the time cap.
final class SvgWorker implements SvgCompilation {
  SvgWorker._(this._limits);

  /// Starts compiling [source] under [limits].
  static SvgCompilation start(SvgSource source, SvgLimits limits) =>
      SvgWorker._(limits).._spawn(source);

  final SvgLimits _limits;
  final Completer<Uint8List?> _result = Completer();
  final RawReceivePort _port = RawReceivePort();
  Isolate? _isolate;
  Timer? _deadline;
  bool _ended = false;

  @override
  Future<Uint8List?> get result => _result.future;

  Future<void> _spawn(SvgSource source) async {
    _port.handler = _answered;
    _deadline = Timer(
      _limits.maxCompileTime,
      () => _end(
        error: SvgRejection(
          SvgRejectionReason.tooSlow,
          '> ${_limits.maxCompileTime.inMilliseconds} ms',
        ),
      ),
    );
    final message = (
      _port.sendPort,
      switch (source) {
        SvgSource$Bytes(:final bytes) => TransferableTypedData.fromList([
          bytes,
        ]),
        SvgSource$File(:final path) => path,
      },
      _limits,
    );
    try {
      final isolate = await Isolate.spawn(
        _work,
        message,
        debugName: 'mpx_svg compile',
        errorsAreFatal: true,
        onExit: _port.sendPort,
      );
      // Cancelled or timed out while it started.
      if (_ended) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    } on Object catch (error) {
      _end(error: SvgRejection(SvgRejectionReason.unreadable, '$error'));
    }
  }

  // The worker's answer: the compiled form, a rejection as (reason, detail),
  // or null when it exited without one.
  void _answered(Object? message) => switch (message) {
    TransferableTypedData() => _end(value: message.materialize().asUint8List()),
    (int reason, String detail) => _end(
      error: SvgRejection(SvgRejectionReason.values[reason], detail),
    ),
    _ => _end(
      error: const SvgRejection(
        SvgRejectionReason.unreadable,
        'the compile worker ended without an answer',
      ),
    ),
  };

  @override
  void cancel() => _end();

  void _end({Uint8List? value, SvgRejection? error}) {
    if (_ended) return;
    _ended = true;
    _deadline?.cancel();
    _port.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    if (error != null) {
      _result.completeError(error);
    } else {
      _result.complete(value);
    }
  }

  static void _work((SendPort, Object, SvgLimits) message) {
    final (reply, source, limits) = message;
    try {
      final bytes = switch (source) {
        TransferableTypedData() => source.materialize().asUint8List(),
        String() => _read(source, limits),
        _ => throw StateError('unknown source $source'),
      };
      final compiled = SvgCompileJob.run(bytes, limits);
      reply.send(TransferableTypedData.fromList([compiled]));
    } on SvgRejection catch (rejection) {
      reply.send((rejection.reason.index, rejection.detail));
    } on Object catch (error) {
      reply.send((SvgRejectionReason.unreadable.index, '$error'));
    }
  }

  // The file, checked against the input cap before a byte is read.
  static Uint8List _read(String path, SvgLimits limits) {
    final file = File(path);
    final length = file.lengthSync();
    if (length > limits.maxInputBytes) {
      throw SvgRejection(
        SvgRejectionReason.tooLarge,
        '$length > ${limits.maxInputBytes} bytes',
      );
    }
    return file.readAsBytesSync();
  }
}
