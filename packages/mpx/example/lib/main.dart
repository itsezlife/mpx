import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/frame_pool.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_lottie/mpx_lottie.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';

/// The media the example shows: a key, how it renders, the file the origin
/// serves for it, and a label.
const List<(MediaKey, MediaKind, String, String)> _media = [
  (MediaKey.remote('still'), MediaKind.still, 'still.png', 'Still'),
  (
    MediaKey.remote('counter'),
    MediaKind.animatedImage,
    'counter.webp',
    'Animated WebP',
  ),
  (
    MediaKey.remote('square'),
    MediaKind.vectorAnimation,
    'square.json',
    'Lottie',
  ),
  (MediaKey.remote('loop'), MediaKind.video, 'loop.webm', 'Video loop'),
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final stack = await MpxStack.create(
    // Where each key's bytes are. A real host maps its keys to its CDN.
    locate: (descriptor, part) => switch (_fileOf(descriptor.key)) {
      final file? => MediaLocation('https://media.example/$file'),
      null => null,
    },
    cacheDirectory: '${Directory.systemTemp.path}/mpx_example',
    decoders: _decoders,
    // The example's origin answers from the app bundle so it runs offline; a
    // real host leaves `client` out and gets the network.
    client: HttpBytesClient(client: _BundleOrigin()),
  );
  for (final (key, kind, _, _) in _media) {
    stack.pipeline.know(
      MediaDescriptor(key: key, kind: kind, animated: kind != MediaKind.still),
    );
  }
  runApp(MediaApp(stack: stack));
}

String? _fileOf(MediaKey key) => [
  for (final (known, _, file, _) in _media)
    if (known == key) file,
].firstOrNull;

/// The heavy decoders, each over its own native engine. One that cannot start
/// (no native library in this build) is left out, and its kind shows the
/// placeholder.
Future<Map<MediaKind, Decoder>> _decoders(MpxDecoderContext context) async {
  final decoders = <MediaKind, Decoder>{};
  try {
    final engine = await IsolateLottieEngine.spawn();
    final memory = NativeFramePageMemory();
    final cache = FrameCache(directoryPath: null);
    final renderer = LottieFrameRenderer(
      engine: engine,
      memory: memory,
      cache: cache,
      textureHost: context.textures?.host,
    );
    final scheduler = LottieFrameScheduler(
      atlas: FrameAtlas<Object>(
        renderer: renderer,
        memory: memory,
        memoryPressure: context.memoryPressure,
      ),
      clock: context.clock,
      textures: context.textures,
      textureWriter: context.textures == null ? null : renderer,
    );
    // Teardowns run last first: the engine closes before the memory its
    // isolate writes into is freed.
    context
      ..onDispose(memory.dispose)
      ..onDispose(engine.close)
      ..onDispose(cache.dispose)
      ..onDispose(scheduler.dispose);
    decoders[MediaKind.vectorAnimation] = LottieDecoder(
      engine: engine,
      scheduler: scheduler,
      cache: cache,
    );
  } on Object catch (reason) {
    debugPrint('Lottie is off: $reason');
  }
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
    context
      ..onDispose(engine.dispose)
      ..onDispose(scheduler.dispose);
    decoders[MediaKind.video] = VideoDecoder(
      engine: engine,
      scheduler: scheduler,
    );
  } on Object catch (reason) {
    debugPrint('Video is off: $reason');
  }
  return decoders;
}

/// Serves `https://media.example/<file>` from `assets/media/<file>`.
final class _BundleOrigin extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      final data = await rootBundle.load(
        'assets/media/${request.url.pathSegments.last}',
      );
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return http.StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length,
        request: request,
      );
    } on Object {
      // Not in the bundle: the origin has no such file.
      return http.StreamedResponse(const Stream.empty(), 404, request: request);
    }
  }
}

/// The example's media drawn by the stack's asset cache, and the device
/// signals that pause it.
class MediaApp extends StatefulWidget {
  const MediaApp({required this.stack, super.key});

  final MpxStack stack;

  @override
  State<MediaApp> createState() => _MediaAppState();
}

class _MediaAppState extends State<MediaApp> {
  @override
  void dispose() {
    widget.stack.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final signals = widget.stack.signals;
    return MaterialApp(
      home: AssetCacheProvider(
        scope: widget.stack.scope,
        child: Scaffold(
          appBar: AppBar(title: const Text('mpx')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final (key, _, _, label) in _media)
                    _MediaTile(content: key, label: label),
                ],
              ),
              const SizedBox(height: 24),
              _SignalTile(label: 'Network', listenable: signals.network),
              _SignalTile(
                label: 'Power saving',
                listenable: signals.powerSaving,
              ),
              _SignalTile(label: 'Thermal', listenable: signals.thermal),
            ],
          ),
        ),
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({required this.content, required this.label});

  static const double _extent = 160;

  final MediaKey content;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ContentView(
        content: content,
        preset: AssetPresets.square(
          extent: _extent,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          profile: const AssetProfile(animate: true),
        ),
      ),
      const SizedBox(height: 8),
      Text(label),
    ],
  );
}

class _SignalTile extends StatelessWidget {
  const _SignalTile({required this.label, required this.listenable});

  final String label;
  final ValueListenable<Object> listenable;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: listenable,
    builder: (context, value, _) => ListTile(
      title: Text(label),
      trailing: Text(switch (value) {
        Enum(:final name) => name,
        _ => '$value',
      }),
    ),
  );
}
