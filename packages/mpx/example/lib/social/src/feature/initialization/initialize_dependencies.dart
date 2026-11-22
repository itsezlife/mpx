import 'dart:async';
import 'dart:io';

import 'package:control/control.dart';
import 'package:flutter/foundation.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:l/l.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx/native.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/common/media/media_origins.dart';
import 'package:mpx_example/social/src/feature/initialization/controller_observer.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:mpx_example/social/src/feature/initialization/initialization_context.dart';
import 'package:mpx_example/social/src/feature/initialization/initialization_metrics.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/inline_sound.dart';
import 'package:mpx_example/social/src/feature/timeline/data/mastodon_client.dart';
import 'package:mpx_example/social/src/feature/timeline/data/timeline_repository.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/native.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';

/// Initializes the app and returns a [Dependencies] object.
///
/// Runs [_initializationSteps] in order, each over the container the earlier
/// ones filled. A step that throws ends the run with its name.
Future<Dependencies> $initializeDependencies({
  void Function(int progress, String message)? onProgress,
}) async {
  final dependencies = Dependencies();
  final context = InitializationContext();
  final totalSteps = _initializationSteps.length;
  var currentStep = 0;
  final stepMetrics = <InitializationStepMetric>[];
  final overall = Stopwatch()..start();
  for (final step in _initializationSteps.entries) {
    final stepWatch = Stopwatch()..start();
    try {
      currentStep++;
      final percent = (currentStep * 100 ~/ totalSteps).clamp(0, 100);
      onProgress?.call(percent, step.key);
      l.v6(
        'Initialization '
        '| ${currentStep.toString().padLeft(2, '0')}/'
        '${totalSteps.toString().padLeft(2, '0')} '
        '($percent%) | "${step.key}"',
      );
      await step.value(dependencies, context);
      stepWatch.stop();
      stepMetrics.add(
        InitializationStepMetric(name: step.key, elapsed: stepWatch.elapsed),
      );
      l.v6(
        'Initialization | benchmark | "${step.key}" | '
        '${stepWatch.elapsedMilliseconds} ms',
      );
    } on Object catch (error, stackTrace) {
      stepWatch.stop();
      l.e('Initialization failed at step "${step.key}": $error', stackTrace);
      Error.throwWithStackTrace(
        'Initialization failed at step "${step.key}": $error',
        stackTrace,
      );
    }
  }
  overall.stop();
  l.v6(
    'Initialization | benchmark | total | ${overall.elapsedMilliseconds} ms',
  );
  dependencies.initializationMetrics = InitializationMetrics(
    steps: List.unmodifiable(stepMetrics),
    completedAt: DateTime.now(),
  );
  return dependencies;
}

typedef _InitializationStep =
    FutureOr<void> Function(
      Dependencies dependencies,
      InitializationContext context,
    );

// The order is the dependency order: each step reads what the ones above it
// filled. The stack needs the origins (its fetcher asks them where media
// live) and the client; the players need the stack's native reader; the
// repository needs the client and the origins.
final Map<String, _InitializationStep> _initializationSteps =
    <String, _InitializationStep>{
      'Observer state management': (_, _) {
        Controller.observer = const ControllerObserver();
      },
      // The calendar dates of a post's age read intl's locale data, which a
      // locale other than the default one loads before first use.
      'Initialize date formatting': (_, _) => initializeDateFormatting('en'),
      'Initialize media origins': (dependencies, _) {
        dependencies.origins = MediaOrigins();
      },
      'Initialize Mastodon client': (dependencies, _) {
        dependencies.mastodonClient = MastodonClient();
      },
      'Initialize media stack': (dependencies, context) async {
        final origins = dependencies.origins;
        final stack = dependencies.stack = await MpxStack.create(
          locate: origins.locate,
          cacheDirectory: '${Directory.systemTemp.path}/mpx_social',
          decoders: _decoders,
          // A clip whose codec the software decoder was built without (AV1,
          // HEVC) still gets a first-frame still, drawn once by the platform.
          fallbackDecoders: {
            if (_hasPlatformStill) MediaKind.video: PlatformStillDecoder(),
          },
          // The process's one native reader, over the stack's ranged
          // resources: the software decoder streams a clip through it, and
          // the players read their source through it, so a clip is
          // downloaded once.
          publisher: (ranged) => NativeRangedReaders.isAvailable
              ? NativeRangedContentPublisher(
                  context.readers = NativeRangedReaders(ranged),
                )
              : null,
        );
        // The stack exists now: what the data layer learns of media goes to
        // its pipeline.
        origins.tellCache = stack.pipeline.know;
      },
      'Initialize feed signals': (dependencies, _) {
        final signals = dependencies.stack.signals;
        dependencies.feedSignals = FeedSignals.adapt(
          network: signals.network,
          toNetwork: (value) => FeedNetwork.values.byName(value.name),
          powerSaving: signals.powerSaving,
          thermal: signals.thermal,
          toThermal: (value) => FeedThermal.values.byName(value.name),
        );
      },
      'Initialize players': (dependencies, context) async {
        dependencies.players = await _players(
          context.readers,
          dependencies.stack.scope,
          dependencies.origins,
        );
      },
      'Initialize inline sound': (dependencies, _) {
        dependencies.inlineSound = InlineSound(dependencies.players);
      },
      'Initialize timeline repository': (dependencies, _) {
        dependencies.timelineRepository = MastodonTimelineRepository(
          client: dependencies.mastodonClient,
          origins: dependencies.origins,
        );
      },
    };

/// Whether the platform draws a still of a video (Android, iOS, macOS).
bool get _hasPlatformStill =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      _ => false,
    };

// The software video decoder over its own native engine. One that cannot
// start (no native library in this build) is left out, and videos show their
// stills.
Future<Map<MediaKind, Decoder>> _decoders(MpxDecoderContext context) async {
  try {
    final engine = await IsolateVideoEngine.spawn();
    final textures = context.textures;
    final scheduler = VideoFrameScheduler(
      engine: engine,
      atlas: VideoFrameAtlas.create(memoryPressure: context.memoryPressure),
      clock: context.clock,
      textures: textures,
      textureWriter: textures == null
          ? null
          : VideoFrameTextureWriter(engine: engine, host: textures.host),
    );
    // Teardowns run last first: the scheduler goes before its engine.
    context
      ..onDispose(engine.dispose)
      ..onDispose(scheduler.dispose);
    return {
      MediaKind.video: VideoDecoder(engine: engine, scheduler: scheduler),
    };
  } on Object catch (reason, stackTrace) {
    l.w('Video is off: $reason', stackTrace);
    return const {};
  }
}

// The platform player over the stack's cache, or null without a native
// reader.
Future<PlayerPool?> _players(
  NativeRangedReaders? readers,
  AssetCacheScope scope,
  MediaOrigins origins,
) async {
  if (readers == null) return null;
  // Which content each source the players read is, so the bytes they pull
  // count as that content's download on every surface of it.
  final contentOf = <BytesCacheKey, MediaKey>{};
  BytesCacheKey cacheKeyOf(MediaKey key) {
    final cacheKey = BytesCacheFetcher.cacheKeyOf(key, FetchPart.content);
    contentOf[cacheKey] = key;
    return cacheKey;
  }

  final backend = NativePlayerBackend(
    readers: readers,
    sourcesOf: (key) => origins.playerSources(key, cacheKeyOf),
    watchSource: (source) => switch (contentOf[source.cacheKey]) {
      final key? => scope.openOutsideReader(key),
      null => null,
    },
  );
  // Prepared players only where the device can hold them.
  return PlayerPool(backend: backend, budget: (await backend.device).budget);
}
