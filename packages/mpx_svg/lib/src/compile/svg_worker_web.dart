import 'dart:async';
import 'dart:typed_data';

import 'package:mpx_svg/src/compile/svg_compile_job.dart';
import 'package:mpx_svg/src/compile/svg_compiler.dart';
import 'package:mpx_svg/src/policy/svg_limits.dart';
import 'package:mpx_svg/src/policy/svg_sanitizer.dart';

/// A compile where there are no isolates (the web): run in place, on the
/// next event, so the caller returns first. The time cap cannot stop it; the
/// sanitizer's counts and the input cap are what bound it here.
final class SvgWorker implements SvgCompilation {
  SvgWorker._();

  /// Starts compiling [source] under [limits].
  static SvgCompilation start(SvgSource source, SvgLimits limits) {
    final worker = SvgWorker._();
    Timer.run(() {
      if (worker._result.isCompleted) return;
      try {
        final compiled = switch (source) {
          SvgSource$Bytes(:final bytes) => SvgCompileJob.run(bytes, limits),
          SvgSource$File() => throw const SvgRejection(
            SvgRejectionReason.unreadable,
            'no files on the web: the fetcher must hand bytes',
          ),
        };
        worker._result.complete(compiled);
      } on SvgRejection catch (rejection) {
        worker._result.completeError(rejection);
      }
    });
    return worker;
  }

  final Completer<Uint8List?> _result = Completer();

  @override
  Future<Uint8List?> get result => _result.future;

  @override
  void cancel() {
    if (!_result.isCompleted) _result.complete(null);
  }
}
