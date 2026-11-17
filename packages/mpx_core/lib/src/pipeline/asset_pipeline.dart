import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/asset/asset_cache_budgets.dart';
import 'package:mpx_core/src/asset/asset_paintable.dart';
import 'package:mpx_core/src/asset/asset_preload.dart';
import 'package:mpx_core/src/asset/asset_producer.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/asset_spec.dart';
import 'package:mpx_core/src/asset/mini_thumbnail.dart';
import 'package:mpx_core/src/asset/outline_paintable.dart';
import 'package:mpx_core/src/asset/svg_path_data.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/image/image_paintable.dart';
import 'package:mpx_core/src/pipeline/auto_download.dart';
import 'package:mpx_core/src/pipeline/cancellation_token.dart';
import 'package:mpx_core/src/pipeline/content_fetcher.dart';
import 'package:mpx_core/src/pipeline/decoder.dart';
import 'package:mpx_core/src/pipeline/descriptor_directory.dart';
import 'package:mpx_core/src/pipeline/media_resolver.dart';
import 'package:mpx_core/src/pipeline/preview_store.dart';
import 'package:mpx_core/src/pipeline/priority_lane.dart';

/// How much the pipeline does at once, and how much it remembers.
@immutable
final class AssetPipelineLimits {
  /// Creates limits; the defaults are described on each field.
  const AssetPipelineLimits({
    this.maxConcurrentFetches = 6,
    this.maxConcurrentDecodes = 2,
    this.maxFetchedAwaitingDecode = 16,
    this.knownDescriptors = 4096,
    this.decodedPreviews = 256,
  }) : assert(
         maxConcurrentFetches > 0 &&
             maxConcurrentDecodes > 0 &&
             maxFetchedAwaitingDecode > 0 &&
             knownDescriptors > 0 &&
             decodedPreviews > 0,
         'every limit is at least one',
       );

  /// Fetches running at once: one lane of 6 serves small and large file loads
  /// alike, because the size of a download is not known before it starts.
  final int maxConcurrentFetches;

  /// Decodes running at once. Decoders may work off the UI isolate, but a
  /// screenful of them would still compete with the frames that show the
  /// result.
  final int maxConcurrentDecodes;

  /// Fetched content that may wait for a decode slot before new fetches are
  /// held back. Bounds the bytes sitting in memory when decoding is slower
  /// than the network.
  final int maxFetchedAwaitingDecode;

  /// Descriptors remembered (host-given and resolved); the least recently
  /// used one is forgotten first and asked for again if it is needed.
  final int knownDescriptors;

  /// Decoded previews kept for the next attach of their content, whatever
  /// its spec; the least recently used one is decoded again if it is needed.
  /// A 40 px preview is about 6 KB, so the default 256 hold about 1.6 MB.
  final int decodedPreviews;
}

/// Why the pipeline could not make an entry, when the cause is not a fetch or
/// decode failure.
final class AssetPipelineError implements Exception {
  /// Creates an error about [key] explained by [message].
  const AssetPipelineError(this.key, this.message);

  /// The content that could not be made.
  final MediaKey key;

  /// What is missing.
  final String message;

  @override
  String toString() => 'AssetPipelineError($key): $message';
}

/// The `AssetProducer` that makes the entries of an `AssetCacheScope` by
/// fetching and decoding: resolve what is unknown, fetch through the host's
/// [ContentFetcher], decode with the [Decoder] of the content's media form,
/// and report stages.
///
/// The scope already runs one attempt per entry and cancels it when the last
/// binding leaves; the pipeline adds what a screenful of entries needs on top:
///
/// - **Priority.** Work is served in classes: a thumbnail (the stand-in)
///   before content a surface is waiting for (`AssetPriority.visible`), and
///   that before content only kept attached (`AssetPriority.preload`); oldest
///   first within a class. The class of content work follows the entry's
///   `AssetDemand` while it waits. Running work is never preempted.
/// - **Caps.** At most `AssetPipelineLimits.maxConcurrentFetches` fetches and
///   `maxConcurrentDecodes` decodes run; fetched content waits for a decode
///   slot, and fetching is held back when too much waits.
/// - **Cancel.** Work still queued is dropped, a running fetch gets its
///   token cancelled and a running decode its task cancelled, and the slot is
///   free at once.
/// - **Unknown descriptors.** A key the pipeline has no descriptor for (see
///   [know]) goes to the host's [MediaResolver], batched with the others
///   asked for in the same turn; the entry stays at `AssetStage.none` until
///   it resolves.
/// - **Previews.** A descriptor that carries a raster preview
///   (`MediaDescriptor.preview`) has it decoded, blurred with [PreviewBlur],
///   and reported as `AssetStage.preview`, before and beside the fetches:
///   it takes no fetch slot and waits behind none. Decoded previews are kept
///   per content (`AssetPipelineLimits.decodedPreviews`), so the next attach
///   of the content, at any spec, draws its preview inside `produce`. A
///   template decode (alpha only) draws none.
/// - **Derived previews.** With a [PreviewStore], content whose descriptor
///   carries no preview reads one from the store (from memory at once, else
///   from disk before the thumbnail fetch is queued); one that lands after a
///   higher stage is dropped. Content that has none in either derives one
///   when its first frame or full stage is decoded: the frame is drawn into
///   at most 40 px, PNG-encoded unblurred and written, once per content per
///   process, from the decoded picture (a playing one lends its first-frame
///   still), never from the content's file. Vector animations derive none:
///   their outline is the host's.
/// - **Staged preloads.** While only staged preloads hold an entry
///   (`AssetDemand.preloadStage`), the attempt stops at their stage: after the
///   resolve for `metadata`, after a prefix fetch (`FetchRequest.prefix`, not
///   decoded) for `seconds`, after the first frame for `firstFrame`. It ends
///   as cancelled, not failed. Among preloads, the nearest
///   (`AssetDemand.distance`) is served first.
/// - **Fallback decoders.** Content the kind's decoder reports as
///   `DecodeFailure.unsupported` is fetched again (from the cache that now
///   holds it) and decoded by the kind's fallback
///   (`DecoderRegistry.registerFallback`), once per attempt. A fallback that
///   draws only a still ends the entry at `AssetStage.firstFrame`, final for
///   its spec, and the still becomes the content's derived preview. Content
///   that already has a stored derived preview is not handed to the fallback
///   again: its still was drawn once, and the preview stands for it.
/// - **Downloads.** Content the fetcher reports missing
///   (`ContentFetcher.needsDownload`) is announced from the start of the
///   attempt (`AssetProgress.waiting`), and the bytes of its transfer are
///   reported as they arrive (`AssetProgress.transfer`). Once its descriptor
///   is known, the scope's auto-download answer (`AssetDemand.autoDownload`)
///   decides: `now` fetches it; `prefix` fetches the stand-ins and a head of
///   the content (its first 4 s, held, not decoded); `manual` fetches the
///   stand-ins only. Both report the content as awaiting the user and end
///   as cancelled once the stand-ins are done. Content held in a cache
///   ignores the policy.
///
/// ## Failure
///
/// No failed picture: a failed attempt ends and the entry keeps its stage;
/// a download under way reads as failed in its transfer.
/// A failed fetch is transient or permanent as the fetcher says (anything but
/// a `FetchFailure` counts as transient); a resolver that throws is
/// transient; a key the resolver leaves out, no resolver, no decoder for the
/// media form and a decode failure are permanent. A failed thumbnail or
/// preview is ignored: the content may still arrive. A failure waits for a
/// preview still decoding, so content no decoder reads still shows it.
///
/// Single-threaded on the UI isolate, like the scope.
final class AssetPipeline implements AssetProducer {
  /// Creates a pipeline over [fetcher] and [decoders].
  AssetPipeline({
    required ContentFetcher fetcher,
    required DecoderRegistry decoders,
    MediaResolver? resolver,
    AssetPipelineLimits limits = const AssetPipelineLimits(),
    PreviewBlur? previewBlur,
    PreviewStore? previews,
  }) : _fetcher = fetcher,
       _previewStore = previews,
       _decoders = decoders,
       _previewBlur =
           previewBlur ?? PreviewBlur.forPlatform(defaultTargetPlatform),
       _previews = _DecodedPreviews(limits.decodedPreviews),
       _directory = DescriptorDirectory(
         capacity: limits.knownDescriptors,
         resolver: resolver,
       ) {
    _decodeLane = PriorityLane(
      capacity: limits.maxConcurrentDecodes,
      start: _startDecode,
      waits: _held,
    );
    _fetchLane = PriorityLane(
      capacity: limits.maxConcurrentFetches,
      start: _startFetch,
      canStart: () =>
          _decodeLane.waitingCount < limits.maxFetchedAwaitingDecode,
      waits: _held,
    );
  }

  final ContentFetcher _fetcher;
  final DecoderRegistry _decoders;
  final DescriptorDirectory _directory;
  final PreviewBlur _previewBlur;
  final PreviewStore? _previewStore;
  // The content whose preview is being derived now: a second attempt does
  // not derive it again meanwhile. Once stored, the store answers for it.
  final Set<MediaKey> _deriving = {};
  final _DecodedPreviews _previews;
  late final PriorityLane<_Work> _fetchLane;
  late final PriorityLane<_Work> _decodeLane;
  final Set<_Job> _jobs = {};
  bool _disposed = false;

  /// Tells the pipeline what the host already knows about content, so its
  /// entries need no resolver round trip. Replaces what was known for the
  /// descriptor's key.
  @override
  void know(MediaDescriptor descriptor) => _directory.add(descriptor);

  /// Cancels every attempt and forgets every descriptor. Idempotent. The
  /// fetcher, the decoders and the resolver stay the host's to dispose.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final job in List<_Job>.of(_jobs)) {
      job.cancel();
    }
    _directory.dispose();
    _previews.dispose();
  }

  // Encodes the frame drawn in [picture] and keeps it as the preview of
  // [key]: in the store, and decoded for the next attach of the process.
  Future<void> _storeDerived(
    MediaKey key,
    ui.Picture picture,
    int width,
    int height,
  ) async {
    final store = _previewStore!;
    try {
      final image = await picture.toImage(width, height);
      final ByteData? data;
      try {
        data = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }
      if (data == null || _disposed) return;
      final png = data.buffer.asUint8List();
      store.write(key, png);
      (await _previews.decode(key, png, _previewBlur))?.dispose();
    } on Object {
      // A frame that cannot be encoded leaves the content without a stored
      // preview: it shows as before, and the next process derives again.
      return;
    } finally {
      picture.dispose();
      _deriving.remove(key);
    }
  }

  // Whether preload work waits ([holdPreloads]).
  bool _preloadsHeld = false;

  bool _held(_Work work) =>
      _preloadsHeld && work.priority == AssetPriority.preload;

  @override
  void holdPreloads({required bool held}) {
    if (_preloadsHeld == held) return;
    _preloadsHeld = held;
    if (held) return;
    _decodeLane.pump();
    _fetchLane.pump();
  }

  @override
  AssetTask produce(
    AssetRequest request,
    AssetProgress progress,
    AssetDemand demand,
  ) {
    if (_disposed) throw StateError('AssetPipeline.produce after dispose.');
    final job = _Job(this, request, progress, demand);
    _jobs.add(job);
    job.start();
    return job;
  }

  void _startFetch(_Work work) {
    work.phase = _Phase.fetching;
    final token = work.token = CancellationToken();
    work.prefix = switch (work.job.demand.preloadStage) {
      _ when work.headOnly => _Job.prefixHead,
      AssetPreloadStage$Seconds(:final duration)
          when work.part == FetchPart.content =>
        duration,
      _ => null,
    };
    Future<FetchedContent> result;
    try {
      result = _fetcher.fetch(
        FetchRequest(
          descriptor: work.job.descriptor!,
          part: work.part,
          priority: work.priority,
          cancellation: token,
          onProgress: work.received,
          prefix: work.prefix,
          whole:
              work.part == FetchPart.content &&
              work.prefix == null &&
              work.job.demand.downloadRequested,
        ),
      );
    } on Object catch (error, stackTrace) {
      result = Future<FetchedContent>.error(error, stackTrace);
    }
    result.then(work.fetched, onError: work.fetchFailed);
  }

  void _startDecode(_Work work) {
    // Fetching may be waiting for the room this start made.
    work.phase = _Phase.decoding;
    final progress = work.decodeProgress = _DecodeProgress(work);
    try {
      final task = work.decoder.decode(
        DecodeRequest(
          descriptor: work.job.descriptor!,
          spec: work.job.request.spec,
          part: work.part,
          content: work.content!,
        ),
        progress,
      );
      if (progress.ended) {
        task.cancel();
      } else {
        progress.task = task;
      }
    } on Object catch (error, stackTrace) {
      // A decoder that throws did not take the content.
      work.content!.release();
      progress.fail(error, stackTrace);
    }
    _fetchLane.pump();
  }
}

enum _Phase { queuedFetch, fetching, queuedDecode, decoding, done }

/// One attempt at one entry.
final class _Job implements AssetTask {
  _Job(this.pipeline, this.request, this.progress, this.demand);

  final AssetPipeline pipeline;
  final AssetRequest request;
  final AssetProgress progress;
  final AssetDemand demand;
  MediaDescriptor? descriptor;
  _Work? _thumbnail;
  _Work? _content;
  bool _ended = false;
  bool _resolving = false;

  // Whether the fetcher reported the content missing at the start: its
  // download is announced, and the auto-download decision applies to it.
  bool _missing = false;

  // The auto-download decision for missing content, as last announced.
  AutoDownload _decision = AutoDownload.now;

  // The total the last transfer report gave, if any.
  int? _lastTotal;

  // Whether the attempt fetches only the stand-ins (and a head of the
  // content): the decision was not to download now. It ends as cancelled
  // once they are done, with the content awaiting the user.
  bool _standInsOnly = false;

  /// How much of the content a [AutoDownload.prefix] decision fetches.
  static const Duration prefixHead = Duration(seconds: 4);

  void start() {
    final known = pipeline._directory.lookup(request.key);
    // Before the resolve and the thumbnail, which may each take a round trip:
    // a surface shows the download (or the download control) of missing
    // content from its first frame.
    if (pipeline._fetcher.needsDownload(request.key)) {
      _missing = true;
      _announce(demand.autoDownload(known));
    }
    if (known != null) {
      _begin(known);
    } else if (pipeline._directory.canResolve) {
      _resolving = true;
      pipeline._directory.resolve(request.key, _resolved);
    } else {
      _fail(
        AssetPipelineError(
          request.key,
          'no descriptor is known and the pipeline has no MediaResolver',
        ),
        null,
        AssetFailureKind.permanent,
      );
    }
  }

  void _resolved(
    MediaDescriptor? resolved,
    Object? error,
    StackTrace? stackTrace,
  ) {
    _resolving = false;
    if (_ended) return;
    if (error != null) {
      _fail(error, stackTrace, AssetFailureKind.transient);
    } else if (resolved == null) {
      _fail(
        AssetPipelineError(request.key, 'the resolver does not know it'),
        null,
        AssetFailureKind.permanent,
      );
    } else {
      _begin(resolved);
    }
  }

  void _announce(AutoDownload decision) {
    _decision = decision;
    if (decision == AutoDownload.now) {
      progress.waiting();
    } else {
      progress.awaitingUser();
    }
  }

  void _begin(MediaDescriptor known) {
    progress.describe(known);
    // describe may end the job: a scope disposed by a listener.
    if (_ended) return;
    // The policy weighs the descriptor, which only now may be known.
    if (_missing) {
      final decision = demand.autoDownload(known);
      if (decision != _decision) _announce(decision);
    }
    final staged = demand.preloadStage;
    if (staged == AssetPreloadStage.metadata) {
      // The descriptor is all a metadata preload wants; the directory keeps
      // it for the attempt a binding starts later.
      descriptor = known;
      satisfied();
      return;
    }
    // A prefix is for a player, which draws no stand-in from the pipeline.
    if (staged is! AssetPreloadStage$Seconds) _preview(known);
    if (_ended) return;
    final decoder = pipeline._decoders.decoderFor(known.kind);
    if (decoder == null) {
      _fail(
        AssetPipelineError(
          request.key,
          'no decoder is registered for ${known.kind.name}',
        ),
        null,
        AssetFailureKind.permanent,
      );
      return;
    }
    descriptor = known;
    _standInsOnly = _missing && _decision != AutoDownload.now;
    // Content that waits for the user is not fetched, or only its head.
    final content = switch (_decision) {
      AutoDownload.manual when _standInsOnly => null,
      _ => _content = _Work(
        this,
        FetchPart.content,
        decoder,
      )..headOnly = _standInsOnly,
    };
    final thumbnail = switch (known.thumbnail) {
      null => null,
      _ when staged is AssetPreloadStage$Seconds => null,
      _ => _thumbnail = _Work(this, FetchPart.thumbnail, decoder),
    };
    // The lane picks by priority, so the order of these two only breaks ties.
    if (thumbnail != null) pipeline._fetchLane.enqueue(thumbnail);
    if (!_ended && content != null) pipeline._fetchLane.enqueue(content);
    // enqueue may end the job when a fetcher answers by throwing.
    settleIfIdle();
  }

  /// Ends an attempt that fetches only stand-ins once they are done: the
  /// preview decoded, the thumbnail and the head of the content settled. It
  /// ends as cancelled, not failed; the content awaits the user.
  void settleIfIdle() {
    if (!_standInsOnly || _ended || _previewDecoding != null) return;
    if (_thumbnail case final work? when work.phase != _Phase.done) return;
    if (_content case final work? when work.phase != _Phase.done) return;
    _ended = true;
    pipeline._jobs.remove(this);
    progress.cancelled();
  }

  /// Relays the bytes of the content's transfer to the entry.
  void reportTransfer(int received, int? total) {
    if (total != null && total > 0) _lastTotal = total;
    progress.transfer(received, total);
  }

  /// All of the content arrived, which a fetcher's last report need not say
  /// (nor a fetch that found the announced content after all): a surface
  /// that drew the download shows it complete until the decode.
  void contentFetched({required bool transferred}) {
    if (!transferred && !_missing) return;
    final total = _lastTotal ?? descriptor?.byteSize;
    if (total != null) progress.transfer(total, total);
  }

  // The preview still decoding, while one is.
  Future<void>? _previewDecoding;

  // Draws the preview of [known]: at once when it is decoded already, else
  // once its decode lands, beside the fetches.
  void _preview(MediaDescriptor known) {
    final previews = pipeline._previews;
    final key = request.key;
    if (known.preview case MediaPreview$Outline(
      :final pathData,
      :final viewBox,
    )) {
      _hasPreview = true;
      _outline(pathData, viewBox);
      return;
    }
    // A template decode is alpha only: a picture would show its colours.
    if (request.spec.decodeMode == AssetDecodeMode.template) return;
    switch (known.preview) {
      case MediaPreview$Raster(:final encoded):
        _hasPreview = true;
        if (previews.take(key) case final image?) {
          _advancePreview(image);
          return;
        }
        _landPreview(previews.decode(key, encoded, pipeline._previewBlur));
      case MediaPreview$Outline():
        break;
      case null:
        final store = pipeline._previewStore;
        if (store == null) return;
        if (previews.take(key) case final image?) {
          _hasPreview = _derivedPreview = true;
          _advancePreview(image);
          return;
        }
        if (store.peek(key) case final png?) {
          _hasPreview = _derivedPreview = true;
          _landPreview(previews.decode(key, png, pipeline._previewBlur));
          return;
        }
        _readingStore = true;
        _landPreview(
          store.read(key).then((png) {
            _readingStore = false;
            if (png == null || _cancelled) return null;
            _hasPreview = _derivedPreview = true;
            return previews.decode(key, png, pipeline._previewBlur);
          }),
        );
    }
  }

  // Parsing an outline is cheap: it is drawn inside produce. One that does
  // not parse leaves the stage where it is.
  void _outline(String pathData, MediaDimensions viewBox) {
    final path = SvgPathData.parse(pathData);
    if (path == null) {
      if (kDebugMode) {
        debugPrint(
          'mpx_core: the outline preview of ${request.key} does not parse; '
          'it is not drawn.',
        );
      }
      return;
    }
    progress.advance(
      AssetStage.preview,
      OutlinePaintable(
        path,
        ui.Size(viewBox.width.toDouble(), viewBox.height.toDouble()),
      ),
      // The path data stands for the path's own size.
      bytes: pathData.length * 4,
    );
  }

  // Draws the preview [decoding] lands, unless the attempt was cancelled.
  void _landPreview(Future<ui.Image?> decoding) {
    _previewDecoding = decoding.then((image) {
      _previewDecoding = null;
      if (image == null) return;
      if (_cancelled) {
        image.dispose();
      } else {
        // An attempt that ended already drops it (the scope disposes a
        // report after the end), as it drops a stage below its own.
        _advancePreview(image);
      }
    });
  }

  // Whether the content has a preview: the descriptor's, or a stored one.
  bool _hasPreview = false;

  // Whether the preview is one this or an earlier process derived (from the
  // store or the decoded previews), not one the descriptor carries.
  bool _derivedPreview = false;

  // Whether the store is still asked for one.
  bool _readingStore = false;

  /// Derives the preview of content that has none from [paintable], the
  /// first decoded frame or full stage of its content; see "Derived
  /// previews" on the pipeline.
  void deriveFrom(AssetPaintable paintable) {
    final known = descriptor;
    if (pipeline._previewStore == null ||
        known == null ||
        _hasPreview ||
        _readingStore ||
        known.kind == MediaKind.vectorAnimation ||
        request.spec.decodeMode == AssetDecodeMode.template) {
      return;
    }
    // A playing paintable may draw into a texture: its still is the frame.
    final source = paintable.isAnimated ? paintable.firstFrame : paintable;
    if (source == null) return;
    final size =
        source.pictureSize ??
        paintable.pictureSize ??
        switch (known.dimensions) {
          final dimensions? => ui.Size(
            dimensions.width.toDouble(),
            dimensions.height.toDouble(),
          ),
          null => null,
        };
    if (size == null || size.isEmpty) return;
    if (!pipeline._deriving.add(request.key)) return;
    final (width, height) = _derivedEdge.sizeOf(
      size.width.round(),
      size.height.round(),
    );
    final recorder = ui.PictureRecorder();
    source.paint(
      ui.Canvas(recorder),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      const AssetPaintContext(animate: false),
    );
    unawaited(
      pipeline._storeDerived(
        request.key,
        recorder.endRecording(),
        width,
        height,
      ),
    );
  }

  // The size a derived preview is kept at: at most 40 px, unblurred.
  static const PreviewBlurPass _derivedEdge = PreviewBlurPass(
    maxEdge: 40,
    radius: 0,
  );

  void _advancePreview(ui.Image image) => progress.advance(
    AssetStage.preview,
    StillImagePaintable(image, template: false),
    bytes: image.width * image.height * 4,
  );

  // Whether the scope cancelled the attempt.
  bool _cancelled = false;

  /// The content reached its final stage.
  void contentDone() {
    if (_ended) return;
    _ended = true;
    _contentDone = true;
    _thumbnail?.cancel();
    pipeline._jobs.remove(this);
    if (_restFailure case (:final error, :final stackTrace, :final kind)) {
      _restFailure = null;
      progress.fail(error, stackTrace, kind);
    }
  }

  // Whether the content reached its final stage, its rest possibly still
  // arriving.
  bool _contentDone = false;

  // A failure of the rest that came before the final stage, reported once
  // the spec is final: until then the decode goes on with what the reads
  // fetch, and a failure of theirs ends the attempt anyway.
  ({Object error, StackTrace stackTrace, AssetFailureKind kind})? _restFailure;

  /// The rest behind the reads of streamed content failed. Reported after
  /// the final stage, where the scope counts it as the content's failed
  /// download (AssetProgress.fail); a running attempt is not ended by it.
  void restFailed(Object error, StackTrace stackTrace, AssetFailureKind kind) {
    if (_contentDone) {
      progress.fail(error, stackTrace, kind);
    } else if (!_ended) {
      _restFailure = (error: error, stackTrace: stackTrace, kind: kind);
    }
  }

  void _fail(Object error, StackTrace? stackTrace, AssetFailureKind kind) {
    if (_ended) return;
    _ended = true;
    pipeline._jobs.remove(this);
    _content?.cancel();
    _thumbnail?.cancel();
    // The preview still decoding is drawn first: a failure keeps the best
    // stage reached, and the preview is one.
    switch (_previewDecoding) {
      case final decoding?:
        unawaited(
          decoding.whenComplete(() {
            if (!_cancelled) progress.fail(error, stackTrace, kind);
          }),
        );
      case null:
        progress.fail(error, stackTrace, kind);
    }
  }

  /// Hands the content [work]'s decoder could not read to the kind's
  /// fallback decoder: the content is fetched again (its decoder released
  /// it) and decoded by the fallback. False when there is none to try.
  bool fallBack(_Work work) {
    final known = descriptor;
    if (_ended || work.isFallback || known == null || _derivedPreview) {
      return false;
    }
    final fallback = pipeline._decoders.fallbackFor(known.kind);
    if (fallback == null) return false;
    final retry = _content = _Work(this, FetchPart.content, fallback)
      ..isFallback = true;
    pipeline._fetchLane.enqueue(retry);
    return true;
  }

  /// The content's decoder can make nothing better than the stage the entry
  /// reached for its spec: that stage is final.
  void contentBestReached() {
    if (_ended) return;
    final failure = _restFailure;
    _restFailure = null;
    contentDone();
    progress.bestReached();
    if (failure case (:final error, :final stackTrace, :final kind)) {
      progress.fail(error, stackTrace, kind);
    }
  }

  /// A part failed. A thumbnail's failure is only its own.
  void workFailed(
    _Work work,
    Object error,
    StackTrace? stackTrace,
    AssetFailureKind kind,
  ) {
    if (work.part == FetchPart.content) {
      _fail(error, stackTrace, kind);
    } else {
      settleIfIdle();
    }
  }

  /// The attempt reached the stage of the preloads that hold the entry: it
  /// ends as cancelled, which records no failure.
  void satisfied() {
    if (_ended) return;
    _ended = true;
    pipeline._jobs.remove(this);
    _content?.cancel();
    _thumbnail?.cancel();
    progress.cancelled();
  }

  /// The decoder gave up by itself (`AssetProgress.cancelled`).
  void contentCancelled() {
    if (_ended) return;
    _ended = true;
    pipeline._jobs.remove(this);
    _thumbnail?.cancel();
    progress.cancelled();
  }

  @override
  void cancel() {
    _cancelled = true;
    if (_ended) return;
    _ended = true;
    pipeline._jobs.remove(this);
    if (_resolving) pipeline._directory.cancel(request.key, _resolved);
    _content?.cancel();
    _thumbnail?.cancel();
  }
}

/// One part of an attempt on its way through the lanes.
final class _Work implements LaneWork {
  _Work(this.job, this.part, this.decoder);

  final _Job job;
  final FetchPart part;
  final Decoder decoder;
  _Phase phase = _Phase.queuedFetch;
  CancellationToken? token;
  // The prefix the running fetch asked for, or null for the whole part.
  Duration? prefix;
  // Whether only the head of the content is fetched (AutoDownload.prefix):
  // held, not decoded, and not shown as a download.
  bool headOnly = false;
  // Whether [decoder] is the kind's fallback, decoding content its decoder
  // reported unsupported.
  bool isFallback = false;
  FetchedContent? content;
  _DecodeProgress? decodeProgress;
  bool _cancelled = false;

  AssetPipeline get _pipeline => job.pipeline;

  @override
  AssetPriority get priority => part == FetchPart.thumbnail
      ? AssetPriority.placeholder
      : job.demand.priority;

  @override
  int get distance => job.demand.distance;

  // Whether the fetch of this part reported a transfer.
  bool _transferred = false;

  /// The fetcher's report of the bytes of this part's transfer.
  void received(int received, int? total) {
    // Streamed content reports its bytes after it was handed out, while it
    // is decoded and after its spec is final, until it is released: the
    // scope counts them for the content, so its completion reaches every
    // spec. Any other report after the fetch is stale.
    final streamed = content is FetchedRanged;
    if (phase != _Phase.fetching && !streamed) return;
    _transferred = true;
    reportTransfer(received, total);
  }

  /// Relays the transfer of the content to the entry; a thumbnail is a stand
  /// in, and a head fetched for later a preload, not the download a surface
  /// shows.
  void reportTransfer(int received, int? total) {
    if (_cancelled || part != FetchPart.content || headOnly) return;
    job.reportTransfer(received, total);
  }

  void fetched(FetchedContent fetchedContent) {
    // Nobody will decode it: the attempt ended while it was fetched.
    if (_cancelled) {
      fetchedContent.release();
      return;
    }
    if (prefix != null) {
      // A prefix is fetched to be held, not decoded.
      fetchedContent.release();
      prefix = null;
      _pipeline._fetchLane.release(this);
      if (headOnly) {
        phase = _Phase.done;
        job.settleIfIdle();
      } else if (job.demand.preloadStage is AssetPreloadStage$Seconds) {
        phase = _Phase.done;
        job.satisfied();
      } else {
        // A binding came while the prefix was fetched: the whole part is
        // wanted now, and a prefix does not decode.
        phase = _Phase.queuedFetch;
        _pipeline._fetchLane.enqueue(this);
      }
      return;
    }
    // Content handed out while it still arrives is not all there: its bytes
    // go on being reported as they land.
    if (part == FetchPart.content && fetchedContent is! FetchedRanged) {
      job.contentFetched(transferred: _transferred);
    }
    content = fetchedContent;
    if (fetchedContent case FetchedRanged(:final rest?)) {
      rest.then<void>((_) {}, onError: restFailed);
    }
    phase = _Phase.queuedDecode;
    _pipeline._decodeLane.enqueue(this);
    _pipeline._fetchLane.release(this);
  }

  // The rest behind the reads of streamed content failed: the content's
  // download failed, which its surfaces show as the retry.
  void restFailed(Object error, StackTrace stackTrace) {
    if (_cancelled || part != FetchPart.content) return;
    job.restFailed(error, stackTrace, _kindOf(error));
  }

  static AssetFailureKind _kindOf(Object error) => switch (error) {
    FetchFailure(:final kind) => kind,
    _ => AssetFailureKind.transient,
  };

  void fetchFailed(Object error, StackTrace stackTrace) {
    if (_cancelled) return;
    phase = _Phase.done;
    _pipeline._fetchLane.release(this);
    job.workFailed(this, error, stackTrace, _kindOf(error));
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final was = phase;
    phase = _Phase.done;
    switch (was) {
      case _Phase.queuedFetch:
        _pipeline._fetchLane.remove(this);
      case _Phase.fetching:
        token?.cancel();
        _pipeline._fetchLane.release(this);
      case _Phase.queuedDecode:
        content?.release();
        _pipeline._decodeLane.remove(this);
        _pipeline._fetchLane.pump();
      case _Phase.decoding:
        decodeProgress?.stop();
        _pipeline._decodeLane.release(this);
      case _Phase.done:
        break;
    }
  }
}

/// What a decoder reports to; relays to the scope's progress.
final class _DecodeProgress implements AssetProgress {
  _DecodeProgress(this._work);

  final _Work _work;
  AssetTask? task;
  bool ended = false;

  bool get _live => !ended && !_work._cancelled;

  /// Ends the decode from our side: cancels the decoder's task.
  void stop() {
    if (ended) return;
    ended = true;
    task?.cancel();
  }

  @override
  void advance(
    AssetStage stage,
    AssetPaintable paintable, {
    required int bytes,
    AssetTier tier = AssetTier.still,
  }) {
    if (!_live) {
      paintable.dispose();
      return;
    }
    final job = _work.job;
    // Drawn before the cache takes it: the cache may dispose it at once.
    if (_work.part == FetchPart.content &&
        stage.index >= AssetStage.firstFrame.index) {
      job.deriveFrom(paintable);
    }
    job.progress.advance(stage, paintable, bytes: bytes, tier: tier);
    final spec = job.request.spec;
    final isFinal =
        _work.part == FetchPart.thumbnail ||
        stage == AssetStage.full ||
        (stage == AssetStage.firstFrame &&
            spec.variant == AssetVariant.firstFrame);
    // A fallback's first frame is the best it draws: a still of content
    // whose moving picture this build cannot decode.
    if (!isFinal &&
        _work.isFallback &&
        stage.index >= AssetStage.firstFrame.index) {
      _end();
      job.contentBestReached();
      return;
    }
    if (!isFinal &&
        stage == AssetStage.firstFrame &&
        _work.part == FetchPart.content &&
        job.demand.preloadStage == AssetPreloadStage.firstFrame) {
      // The preloads holding the entry wanted the first frame: the decode
      // stops here, and the attempt a binding starts later goes on.
      stop();
      _work.phase = _Phase.done;
      _work._pipeline._decodeLane.release(_work);
      job.satisfied();
      return;
    }
    if (!isFinal) return;
    _end();
    if (_work.part == FetchPart.content) {
      job.contentDone();
    } else {
      job.settleIfIdle();
    }
  }

  // The job described the content before the decode; a decoder that learns
  // more passes it on.
  @override
  void describe(MediaDescriptor descriptor) {
    if (_live) _work.job.progress.describe(descriptor);
  }

  // A decoder that reads its content from the network (a stream it opens
  // itself) reports the download as a fetcher would.
  @override
  void waiting() {
    if (_live && _work.part == FetchPart.content) _work.job.progress.waiting();
  }

  @override
  void transfer(int received, int? total) {
    if (_live) _work.reportTransfer(received, total);
  }

  @override
  void awaitingUser() {
    if (_live && _work.part == FetchPart.content) {
      _work.job.progress.awaitingUser();
    }
  }

  @override
  void fail(
    Object error, [
    StackTrace? stackTrace,
    AssetFailureKind kind = AssetFailureKind.transient,
  ]) {
    if (!_live) return;
    _end();
    if (error is DecodeFailure &&
        _work.part == FetchPart.content &&
        _work.job.fallBack(_work)) {
      return;
    }
    // Decoding the same data again cannot succeed, whatever the network does.
    _work.job.workFailed(_work, error, stackTrace, AssetFailureKind.permanent);
  }

  @override
  void bestReached() {
    if (!_live) return;
    _end();
    if (_work.part == FetchPart.content) {
      _work.job.contentBestReached();
    } else {
      _work.job.settleIfIdle();
    }
  }

  @override
  void cancelled() {
    if (!_live) return;
    _end();
    if (_work.part == FetchPart.content) {
      _work.job.contentCancelled();
    } else {
      _work.job.settleIfIdle();
    }
  }

  void _end() {
    ended = true;
    _work.phase = _Phase.done;
    _work._pipeline._decodeLane.release(_work);
  }
}

/// The decoded previews of a pipeline, by content, least recently used first,
/// with the decodes still running so two attempts of one content decode its
/// preview once.
final class _DecodedPreviews {
  _DecodedPreviews(this._capacity);

  final int _capacity;
  final LinkedHashMap<MediaKey, ui.Image> _images = LinkedHashMap();
  final Map<MediaKey, Future<ui.Image?>> _decoding = {};
  bool _disposed = false;

  /// A copy of the decoded preview of [key], which the caller owns, or null.
  ui.Image? take(MediaKey key) {
    final image = _images.remove(key);
    if (image == null) return null;
    _images[key] = image;
    return image.clone();
  }

  /// Decodes [encoded] as the preview of [key], keeps it, and answers a copy
  /// the caller owns; null when it does not decode.
  Future<ui.Image?> decode(
    MediaKey key,
    Uint8List encoded,
    PreviewBlur blur,
  ) async {
    final decoded = await (_decoding[key] ??= _run(key, encoded, blur));
    return _disposed ? null : decoded?.clone();
  }

  Future<ui.Image?> _run(
    MediaKey key,
    Uint8List encoded,
    PreviewBlur blur,
  ) async {
    try {
      final image = await MiniThumbnail.decode(encoded, blur);
      if (_disposed) {
        image.dispose();
        return null;
      }
      _keep(key, image);
      return image;
    } on Object {
      // A preview that does not decode is ignored: the thumbnail and the
      // content may still come.
      return null;
    } finally {
      // The decode is no longer running; its future is this one.
      _decoding.removeWhere((decoding, _) => decoding == key);
    }
  }

  void _keep(MediaKey key, ui.Image image) {
    _images.remove(key)?.dispose();
    _images[key] = image;
    while (_images.length > _capacity) {
      _images.remove(_images.keys.first)!.dispose();
    }
  }

  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }
}
