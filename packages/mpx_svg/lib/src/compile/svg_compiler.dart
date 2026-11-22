import 'dart:typed_data';

import 'package:mpx_svg/src/compile/svg_worker_web.dart'
    if (dart.library.io) 'package:mpx_svg/src/compile/svg_worker_vm.dart';
import 'package:mpx_svg/src/policy/svg_limits.dart';
import 'package:mpx_svg/src/policy/svg_sanitizer.dart';

/// Where the SVG to compile is.
sealed class SvgSource {
  /// The document's bytes, in memory.
  const factory SvgSource.bytes(Uint8List bytes) = SvgSource$Bytes;

  /// The document in the file at [path], read where it is compiled, so its
  /// bytes never pass through the caller's isolate. Not on the web.
  const factory SvgSource.file(String path) = SvgSource$File;

  const SvgSource._();
}

/// An [SvgSource] of bytes.
final class SvgSource$Bytes extends SvgSource {
  /// The source [bytes].
  const SvgSource$Bytes(this.bytes) : super._();

  /// The document.
  final Uint8List bytes;
}

/// An [SvgSource] in a file.
final class SvgSource$File extends SvgSource {
  /// The source at [path].
  const SvgSource$File(this.path) : super._();

  /// Where the document is.
  final String path;
}

/// One compile under way.
abstract interface class SvgCompilation {
  /// The compiled form (the vector graphics binary `vector_graphics`
  /// draws), or null once [cancel] was called first. Fails with an
  /// [SvgRejection] for a document the limits or the compiler refuse.
  Future<Uint8List?> get result;

  /// Stops the compile: the worker is ended, not waited for, and [result]
  /// completes with null. Nothing after the result is there.
  void cancel();
}

/// Sanitizes and compiles SVG under a host's [limits], off the UI isolate.
///
/// Each compile runs on a worker isolate of its own (where there are
/// isolates: everywhere but the web, where it runs in place). The worker is
/// ended on [SvgCompilation.cancel] and when it runs past
/// `SvgLimits.maxCompileTime`: a document crafted to slip past the
/// sanitizer's counts must not keep a core busy, and a running isolate cannot
/// be asked to stop, only ended. One isolate per compile costs a spawn (a
/// millisecond or two, sharing the app's code); a shared worker could not be
/// ended for one document without failing the others.
///
/// The result is the compiled form, not a picture: it is plain bytes, so it
/// crosses isolates, can be kept in a cache, and is drawn at any size by
/// whoever holds it (the decoder, or a host's own painter).
final class SvgCompiler {
  /// Creates a compiler holding documents to [limits].
  const SvgCompiler([this.limits = SvgLimits.standard]);

  /// The caps every document is held to.
  final SvgLimits limits;

  /// Starts compiling [source].
  SvgCompilation compile(SvgSource source) => SvgWorker.start(source, limits);
}
