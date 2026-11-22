import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_svg/src/compile/svg_compiler.dart';
import 'package:mpx_svg/src/policy/svg_limits.dart';
import 'package:mpx_svg/src/policy/svg_sanitizer.dart';
import 'package:vector_graphics/vector_graphics.dart';

/// Draws SVG documents as stills of the asset cache, at the spec's pixels.
///
/// The host registers it under `MediaKind.vectorImage`. The content views
/// that draw any media then draw SVG: the same sources (whatever the host's
/// fetcher hands, network and disk tier included), readiness stages,
/// budgets and placeholder.
///
/// | Request | Reports |
/// | --- | --- |
/// | a thumbnail | the picture, as `AssetStage.placeholder` |
/// | content, first frame only | the picture, as `AssetStage.firstFrame` |
/// | content | the picture, as `AssetStage.full` |
///
/// ## Drawn, not kept as vectors
///
/// The document is compiled off the UI isolate (`SvgCompiler`, held to
/// [limits]). It is then drawn once into an image of the spec's size and
/// handed over as a `StillImagePaintable` in the still tier, costing its
/// pixels.
///
/// Keeping the vector picture instead would replay every path on every
/// frame, and its memory has no honest byte count for the budget. An image
/// costs one draw and exactly what the budget charges.
///
/// The picture is fitted inside the spec, keeping its aspect ratio, and
/// scaled up as well as down: a vector has the detail at any size. Its long
/// edge never passes `SvgLimits.maxPixelEdge`. A template spec keeps the
/// colours and the surface tints the alpha at paint (`ContentView.tint`), so
/// a one-colour icon is one entry in every colour it is shown in.
///
/// ## Sizes
///
/// The spec is part of an entry's identity, so the same document at a new
/// size is a new entry, drawn anew. What it was compiled to is kept by media
/// key (up to `SvgLimits.compiledCacheBytes`), so another size skips the
/// parse. Content under one media key never changes, which is what makes
/// that safe.
///
/// ## Failure
///
/// A document the limits refuse ([SvgRejection]), a file it cannot read and
/// a ranged resource are all permanent failures. The surface keeps its
/// placeholder.
final class SvgDecoder implements Decoder {
  /// Creates a decoder holding every document to [limits].
  SvgDecoder({this.limits = SvgLimits.standard})
    : _compiler = SvgCompiler(limits);

  /// The caps every document is held to.
  final SvgLimits limits;

  final SvgCompiler _compiler;

  // Compiled forms, least recently used first.
  final LinkedHashMap<(MediaKey, FetchPart), Uint8List> _compiled =
      LinkedHashMap();
  int _compiledBytes = 0;

  @override
  AssetTask decode(DecodeRequest request, AssetProgress progress) {
    final task = _SvgDecodeTask(this, request, progress);
    unawaited(task.run());
    return task;
  }

  Uint8List? _takeCompiled((MediaKey, FetchPart) key) {
    final compiled = _compiled.remove(key);
    if (compiled != null) _compiled[key] = compiled;
    return compiled;
  }

  void _keep((MediaKey, FetchPart) key, Uint8List compiled) {
    final budget = limits.compiledCacheBytes;
    if (compiled.length > budget) return;
    if (_compiled.remove(key) case final old?) _compiledBytes -= old.length;
    _compiled[key] = compiled;
    _compiledBytes += compiled.length;
    while (_compiledBytes > budget) {
      final oldest = _compiled.keys.first;
      _compiledBytes -= _compiled.remove(oldest)!.length;
    }
  }
}

/// One decode, from fetched content to the reported stage.
final class _SvgDecodeTask implements AssetTask {
  _SvgDecodeTask(this._decoder, this._request, this._progress);

  final SvgDecoder _decoder;
  final DecodeRequest _request;
  final AssetProgress _progress;
  SvgCompilation? _compilation;
  bool _cancelled = false;
  bool _released = false;

  @override
  void cancel() {
    _cancelled = true;
    _compilation?.cancel();
  }

  Future<void> run() async {
    final ui.Image image;
    try {
      final compiled = await _compile();
      // Cancelled meanwhile.
      if (compiled == null || _cancelled) return;
      image = await _draw(compiled);
    } on Object catch (error, stackTrace) {
      _release();
      // What could not be drawn stays that way, whatever the network does.
      if (!_cancelled) {
        _progress.fail(error, stackTrace, AssetFailureKind.permanent);
      }
      return;
    }
    if (_cancelled) {
      image.dispose();
      return;
    }
    final spec = _request.spec;
    _progress.advance(
      switch ((_request.part, spec.variant)) {
        (FetchPart.thumbnail, _) => AssetStage.placeholder,
        (FetchPart.content, AssetVariant.firstFrame) => AssetStage.firstFrame,
        (FetchPart.content, AssetVariant.full) => AssetStage.full,
      },
      StillImagePaintable(
        image,
        template: spec.decodeMode == AssetDecodeMode.template,
      ),
      bytes: image.width * image.height * 4,
    );
  }

  // The compiled form: kept from an earlier request, or compiled from the
  // content now. Null when cancelled.
  Future<Uint8List?> _compile() async {
    final cacheKey = (_request.descriptor.key, _request.part);
    if (_decoder._takeCompiled(cacheKey) case final kept?) {
      _release();
      return kept;
    }
    final source = switch (_request.content) {
      FetchedBytes(:final bytes) => SvgSource.bytes(bytes),
      FetchedFile() when kIsWeb => throw UnsupportedError(
        'SvgDecoder reads no file on the web: the fetcher must hand bytes '
        '(FetchedContent.bytes).',
      ),
      FetchedFile(:final path) => SvgSource.file(path),
      FetchedRanged() => throw UnsupportedError(
        'SvgDecoder reads whole files: the fetcher must not hand it a ranged '
        'resource.',
      ),
    };
    // Bytes are the worker's copy once sent; a file is read there.
    if (_request.content is FetchedBytes) _release();
    final compilation = _compilation = _decoder._compiler.compile(source);
    if (_cancelled) compilation.cancel();
    try {
      final compiled = await compilation.result;
      if (compiled != null) _decoder._keep(cacheKey, compiled);
      return compiled;
    } finally {
      _release();
    }
  }

  // The picture of [compiled] drawn into the spec's pixels.
  Future<ui.Image> _draw(Uint8List compiled) async {
    final info = await vg.loadPicture(_CompiledBytes(compiled), null);
    try {
      final size = _sized(info.size);
      if (size.width <= 0 || size.height <= 0 || !size.isFinite) {
        throw SvgRejection(
          SvgRejectionReason.unreadable,
          'no size to draw at: $size',
        );
      }
      final (width, height) = _fitIn(size);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
        ..scale(width / size.width, height / size.height)
        ..drawPicture(info.picture);
      final scaled = recorder.endRecording();
      try {
        return await scaled.toImage(width, height);
      } finally {
        scaled.dispose();
      }
    } finally {
      info.picture.dispose();
    }
  }

  // [size] with an edge the document left out (no width, or no height, and
  // no view box: the compiler reads it as unbounded) taken from the spec's
  // proportion, as a browser fills its box on the axis it was not given.
  ui.Size _sized(ui.Size size) {
    final spec = _request.spec;
    final aspect = spec.pixelWidth / spec.pixelHeight;
    return switch ((size.width.isFinite, size.height.isFinite)) {
      (false, true) => ui.Size(size.height * aspect, size.height),
      (true, false) => ui.Size(size.width, size.width / aspect),
      _ => size,
    };
  }

  // The pixel size of [size] fitted inside the spec, keeping its aspect
  // ratio, its long edge at most the limits'.
  (int, int) _fitIn(ui.Size size) {
    final spec = _request.spec;
    var scale = math.min(
      spec.pixelWidth / size.width,
      spec.pixelHeight / size.height,
    );
    final edge = _decoder.limits.maxPixelEdge;
    final longest = math.max(size.width, size.height) * scale;
    if (longest > edge) scale *= edge / longest;
    return (
      math.max(1, (size.width * scale).round()),
      math.max(1, (size.height * scale).round()),
    );
  }

  void _release() {
    if (_released) return;
    _released = true;
    _request.content.release();
  }
}

// The compiled form, as the drawing library reads it.
final class _CompiledBytes extends BytesLoader {
  const _CompiledBytes(this._bytes);

  final Uint8List _bytes;

  @override
  Future<ByteData> loadBytes(BuildContext? context) => SynchronousFuture(
    _bytes.buffer.asByteData(_bytes.offsetInBytes, _bytes.length),
  );
}
