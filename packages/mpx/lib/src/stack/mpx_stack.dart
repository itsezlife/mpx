import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/src/download/network_auto_download_policy.dart';
import 'package:mpx/src/fetch/bytes_cache_fetcher.dart';
import 'package:mpx/src/fetch/ranged_content_publisher.dart';
import 'package:mpx/src/preview/bytes_cache_preview_store.dart';
import 'package:mpx/src/signals/device_signals.dart';
import 'package:mpx_core/mpx_core.dart';

/// What a host's [MpxDecoderFactory] builds its decoders over: the parts of
/// the stack that exist before the decoders do.
final class MpxDecoderContext {
  MpxDecoderContext._({
    required this.clock,
    required this.textures,
    required this.memoryPressure,
    required this.store,
    required this.registeredQuotas,
    required List<FutureOr<void> Function()> teardowns,
  }) : _teardowns = teardowns;

  /// The clock every animation of the stack advances on.
  final PlaybackClock clock;

  /// The platform textures playing assets may render into, or null where the
  /// platform has none (or the host turned them off).
  final FrameTexturePool? textures;

  /// Fires when the platform reports memory pressure.
  final Listenable memoryPressure;

  /// The bytes store of the stack.
  final IBytesStore store;

  /// The quotas the host registered, by name, for owners that report usage
  /// (`RegisteredQuota.reportUsage`).
  final Map<String, RegisteredQuota> registeredQuotas;

  final List<FutureOr<void> Function()> _teardowns;

  /// Runs [teardown] when the stack is disposed, after the scope and the
  /// pipeline and before the store closes. Teardowns run in reverse order of
  /// registration, so a decoder registers its engine's close before its
  /// scheduler's dispose.
  void onDispose(FutureOr<void> Function() teardown) =>
      _teardowns.add(teardown);
}

/// Builds the host's decoders, by the kind each reads, over [context].
///
/// Decoders are the host's because each heavy one (vector animation, video)
/// lives in a package of its own that `mpx` does not depend on. A decoder
/// whose engine fails to start is simply left out: its kind keeps its
/// placeholder.
typedef MpxDecoderFactory =
    FutureOr<Map<MediaKind, Decoder>> Function(MpxDecoderContext context);

/// Builds the host's [RangedContentPublisher] over the stack's [ranged]
/// resources, or null for none. Called once, where the store keeps ranged
/// resources (the VM): a native reader is one per process and serves one
/// [RangedBytes], so the host keeps what it builds here for its players.
typedef MpxPublisherFactory =
    RangedContentPublisher? Function(RangedBytes ranged);

/// A media stack assembled in one call: one bytes store, one HTTP client,
/// the fetch adapter, the pipeline, the asset cache scope and the pause
/// layers fed by the device.
///
/// ```
/// host decoders ─┐                   device signals ──> pause layers
///                v                                         │
/// HttpBytesClient ─> BytesCacheFetcher ─> AssetPipeline ─> AssetCacheScope
/// IBytesStore ─────┘ (MediaLocator)     (MediaResolver)     (clock, textures)
/// ```
///
/// The stack owns everything it created and [dispose] releases it; what the
/// host passed in (a client, signals, a resolver) stays the host's. Hosts
/// import the packages whose types they use: `mpx` re-exports nothing.
final class MpxStack {
  MpxStack._({
    required this.store,
    required this.client,
    required this.ranged,
    required this.fetcher,
    required this.pipeline,
    required this.scope,
    required this.activity,
    required this.signals,
    required this.autoDownload,
    required this.registeredQuotas,
    required this.previews,
    required List<FutureOr<void> Function()> teardowns,
  }) : _teardowns = teardowns;

  /// Assembles a stack.
  ///
  /// - [locate] names where media not in the store is fetched from.
  /// - [cacheDirectory] is the store's folder; null keeps bytes in memory
  ///   (the web ignores it and uses its own storage).
  /// - [decoders] builds the host's decoders. The still and animated-image
  ///   kinds default to the engine codecs (`ImageCodecDecoder`); a decoder
  ///   the factory returns for them replaces the default.
  /// - [fallbackDecoders] decode, per kind, the content its decoder reports
  ///   as `DecodeFailure.unsupported` (a platform still for video codecs the
  ///   software decoder was built without); see
  ///   `DecoderRegistry.registerFallback`.
  /// - [registeredQuotas] are folders other owners keep (rendered frames,
  ///   glyph pages), registered with the store so one budget covers them.
  /// - [signals] defaults to the platform's [DeviceSignals]. Power saving and
  ///   a serious or critical thermal status pause playback through
  ///   [PlaybackPauseLayer.lowPower]; the app lifecycle drives the other
  ///   layers ([PlaybackActivity]).
  /// - [rangedParts] splits the ranged downloads into parts, several in
  ///   flight per file; the client's slots cap them in total.
  /// - [client] defaults to an [HttpBytesClient] with the retry, timeout and
  ///   conditional middlewares, whose file-bound GETs run on a transfer
  ///   worker (`HttpBytesTransfers`); a host client is not closed by
  ///   [dispose].
  /// - [publisher] builds what publishes content of some kinds for native
  ///   readers instead of downloading it first (the software video decoder
  ///   reads clips that way); see [MpxPublisherFactory].
  /// - [previews] keeps the previews the pipeline derives; it defaults to a
  ///   [BytesCachePreviewStore] over the stack's store, under
  ///   [BytesQuota.previews]. [previewBlur] is how previews and small
  ///   thumbnails are blurred, the target platform's by default.
  /// - [platformTextures] lends a [FrameTexturePool] over the platform's
  ///   texture host where there is one.
  /// - [autoDownload] decides which missing content downloads by itself.
  ///   It defaults to a [NetworkAutoDownloadPolicy] over [signals] with the
  ///   presets of `defaultTargetPlatform`
  ///   ([AutoDownloadPresets.forPlatform]), which the stack disposes; a
  ///   host policy stays the host's.
  static Future<MpxStack> create({
    required MediaLocator locate,
    String? cacheDirectory,
    MpxDecoderFactory? decoders,
    Map<MediaKind, Decoder> fallbackDecoders = const {},
    MediaResolver? resolver,
    Map<BytesQuota, QuotaEvictor> registeredQuotas = const {},
    IDeviceSignals? signals,
    ValueListenable<bool>? reducedMotion,
    HttpBytesClient? client,
    MpxPublisherFactory? publisher,
    AssetCacheBudgets budgets = AssetCacheBudgets.defaults,
    AssetPipelineLimits limits = const AssetPipelineLimits(),
    PlaybackPolicy playbackPolicy = const PlaybackPolicy(),
    bool platformTextures = true,
    ValueListenable<bool>? scrolling,
    BytesDiagnostics diagnostics = const BytesDiagnostics.silent(),
    AutoDownloadPolicy? autoDownload,
    PreviewStore? previews,
    PreviewBlur? previewBlur,
    RangedParts rangedParts = const RangedParts(),
  }) async {
    final teardowns = <FutureOr<void> Function()>[];
    void own(FutureOr<void> Function() teardown) => teardowns.add(teardown);

    final store = cacheDirectory == null && !kIsWeb
        ? MemoryBytesCache()
        : await BytesCache.open(
            directory: cacheDirectory,
            diagnostics: diagnostics,
          );
    own(store.close);
    final http = client ?? _defaultClient();
    if (client == null) own(http.close);
    final rangedBytes = RangedBytes(
      store: store,
      client: http,
      parts: rangedParts,
    );
    final ranged = rangedBytes.isSupported ? rangedBytes : null;
    if (ranged != null) own(ranged.close);
    final quotas = <String, RegisteredQuota>{
      for (final MapEntry(key: quota, value: onEvict)
          in registeredQuotas.entries)
        quota.name: store.registerQuota(quota, onEvict: onEvict),
    };
    for (final registration in quotas.values) {
      own(registration.unregister);
    }

    final deviceSignals = signals ?? DeviceSignals();
    if (signals == null) own(deviceSignals.dispose);
    final AutoDownloadPolicy downloadPolicy;
    if (autoDownload != null) {
      downloadPolicy = autoDownload;
    } else {
      final policy = NetworkAutoDownloadPolicy(
        deviceSignals,
        presets: AutoDownloadPresets.forPlatform(defaultTargetPlatform),
      );
      own(policy.dispose);
      downloadPolicy = policy;
    }
    final memoryPressure = _MemoryPressure();
    own(memoryPressure.dispose);
    final clock = PlaybackClock(policy: playbackPolicy);
    own(clock.dispose);
    final textureHost = platformTextures
        ? PlatformFrameTextureHost.forPlatform()
        : null;
    final textures = textureHost == null
        ? null
        : FrameTexturePool(host: textureHost, scrolling: scrolling);
    if (textures != null) own(textures.dispose);

    final registry = DecoderRegistry();
    final hostDecoders = await decoders?.call(
      MpxDecoderContext._(
        clock: clock,
        textures: textures,
        memoryPressure: memoryPressure,
        store: store,
        registeredQuotas: Map.unmodifiable(quotas),
        teardowns: teardowns,
      ),
    );
    final byKind = <MediaKind, Decoder>{
      MediaKind.still: const ImageCodecDecoder(),
      MediaKind.animatedImage: const ImageCodecDecoder(),
      ...?hostDecoders,
    };
    byKind.forEach(registry.register);
    fallbackDecoders.forEach(registry.registerFallback);

    final fetcher = BytesCacheFetcher(
      store: store,
      client: http,
      locate: locate,
      ranged: ranged,
      publisher: ranged == null ? null : publisher?.call(ranged),
    );
    final previewStore = previews ?? BytesCachePreviewStore(store);
    final pipeline = AssetPipeline(
      fetcher: fetcher,
      decoders: registry,
      resolver: resolver,
      limits: limits,
      previews: previewStore,
      previewBlur: previewBlur,
    );
    own(pipeline.dispose);
    final scope = AssetCacheScope(
      producer: pipeline,
      budgets: budgets,
      clock: clock,
      memoryPressure: memoryPressure,
      textures: textures,
      autoDownload: downloadPolicy,
    );
    own(scope.dispose);

    final lowPower = _LowPower(deviceSignals);
    own(lowPower.dispose);
    final lifecycle = WidgetsPlaybackLifecycleSource();
    own(lifecycle.dispose);
    final activity = PlaybackActivity(
      clock: clock,
      lifecycle: lifecycle,
      lowPower: lowPower,
      reducedMotion: reducedMotion,
    );
    own(activity.dispose);

    return MpxStack._(
      store: store,
      client: http,
      ranged: ranged,
      fetcher: fetcher,
      pipeline: pipeline,
      scope: scope,
      activity: activity,
      signals: deviceSignals,
      autoDownload: downloadPolicy,
      registeredQuotas: Map.unmodifiable(quotas),
      previews: previewStore,
      teardowns: teardowns,
    );
  }

  // Outermost first: retry over timeout, so each attempt has its own
  // deadline; conditional innermost, so revalidation reaches the wire.
  // Transfers keep the media bytes on a worker isolate; the web, which has
  // none, sends them through the client as before.
  static HttpBytesClient _defaultClient() => HttpBytesClient(
    middlewares: [
      HttpBytesRetryMiddleware().call,
      const HttpBytesTimeoutMiddleware().call,
      const HttpBytesConditionalMiddleware().call,
    ],
    transfers: const HttpBytesTransfers(),
  );

  /// The one bytes store: media, and the registered folders' accounting.
  final IBytesStore store;

  /// The HTTP client the fetcher sends through.
  final HttpBytesClient client;

  /// The ranged resources of [store], or null where it keeps none (memory,
  /// the web). The fetcher fetches media through them; a host's native
  /// reader (players, [MpxPublisherFactory]) serves these and no others.
  final RangedBytes? ranged;

  /// The core's fetch seam, filled from [store] and [client].
  final BytesCacheFetcher fetcher;

  /// Fetches and decodes; `know` tells it descriptors the host already has.
  final AssetPipeline pipeline;

  /// What surfaces attach to (hand it down with `AssetCacheProvider`).
  final AssetCacheScope scope;

  /// Drives the pause layers from the app lifecycle and the device.
  final PlaybackActivity activity;

  /// The device signals the stack reads; a player or a feed policy may read
  /// them too.
  final IDeviceSignals signals;

  /// Which missing content downloads by itself (the scope's policy).
  final AutoDownloadPolicy autoDownload;

  /// The registered quotas by name.
  final Map<String, RegisteredQuota> registeredQuotas;

  /// Where the pipeline keeps the previews it derives.
  final PreviewStore previews;

  final List<FutureOr<void> Function()> _teardowns;
  bool _disposed = false;

  /// Releases what the stack created, last created first. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final teardown in _teardowns.reversed.toList()) {
      await teardown();
    }
    _teardowns.clear();
  }
}

// Power is short when the device saves it or runs hot enough to throttle.
final class _LowPower extends ValueNotifier<bool> {
  _LowPower(this._signals) : super(_read(_signals)) {
    _signals.powerSaving.addListener(_update);
    _signals.thermal.addListener(_update);
  }

  final IDeviceSignals _signals;

  static bool _read(IDeviceSignals signals) =>
      signals.powerSaving.value ||
      signals.thermal.value.index >= ThermalStatus.serious.index;

  void _update() => value = _read(_signals);

  @override
  void dispose() {
    _signals.powerSaving.removeListener(_update);
    _signals.thermal.removeListener(_update);
    super.dispose();
  }
}

// The platform's memory-pressure report as a listenable.
final class _MemoryPressure extends ChangeNotifier with WidgetsBindingObserver {
  _MemoryPressure() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didHaveMemoryPressure() => notifyListeners();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
