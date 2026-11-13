import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/frame_pool.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/feed_page.dart';
import 'package:mpx_example/gallery.dart';
import 'package:mpx_lottie/mpx_lottie.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/native.dart';
import 'package:mpx_ui/mpx_ui.dart';
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
  (MediaKey.remote('clip'), MediaKind.video, 'clip.mp4', 'Video with sound'),
];

/// The key whose viewer page plays with sound on the platform player.
const MediaKey _soundClip = MediaKey.remote('clip');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Rendered Lottie frames keep a folder of their own, counted against the
  // store's one budget as its `lottie_frames` quota: no sweep of our own.
  final frames = FrameCache(
    directoryPath: '${Directory.systemTemp.path}/mpx_example_frames',
    diskBudgetBytes: null,
  );
  final stack = await MpxStack.create(
    // Where each key's bytes are. A real host maps its keys to its CDN.
    locate: (descriptor, part) => switch (_fileOf(descriptor.key)) {
      final file? => MediaLocation('https://media.example/$file'),
      null => null,
    },
    cacheDirectory: '${Directory.systemTemp.path}/mpx_example',
    registeredQuotas: {BytesQuota.lottieFrames: frames.evict},
    decoders: (context) => _decoders(context, frames),
    // The example's origin answers from the app bundle so it runs offline; a
    // real host leaves `client` out and gets the network.
    client: HttpBytesClient(client: _BundleOrigin()),
  );
  for (final (key, kind, _, _) in _media) {
    stack.pipeline.know(
      MediaDescriptor(key: key, kind: kind, animated: kind != MediaKind.still),
    );
  }
  runApp(MediaApp(stack: stack, players: await _players(stack)));
}

/// The platform player over the stack's cache: the viewer plays videos with
/// sound on it, reading their bytes through the cache's native reader. Null
/// where there is no native reader (the viewer then shows stills).
Future<PlayerPool?> _players(MpxStack stack) async {
  if (!NativeRangedReaders.isAvailable) return null;
  final ranged = RangedBytes(store: stack.store, client: stack.client);
  if (!ranged.isSupported) return null;
  // The example logs the players' lifecycle, so a problem seen on a device
  // can be traced in its log.
  PlayerDiagnostics.enabled = true;
  final backend = NativePlayerBackend(
    readers: NativeRangedReaders(ranged),
    sourcesOf: (key) => switch (_fileOf(key)) {
      final file? => [
        PlayerSource(
          RangedRequest(
            url: Uri.parse('https://media.example/$file'),
            // Its own entry: the player reads a sparse file of ranges, the
            // software decoder the whole body.
            cacheKey: BytesCacheKey('ranged-${key.encoded}'),
          ),
          mimeType: file.endsWith('.webm') ? 'video/webm' : 'video/mp4',
        ),
      ],
      null => const [],
    },
  );
  // Prepared players only where the device can hold them.
  return PlayerPool(backend: backend, budget: (await backend.device).budget);
}

String? _fileOf(MediaKey key) => [
  for (final (known, _, file, _) in _media)
    if (known == key) file,
].firstOrNull;

/// The heavy decoders, each over its own native engine. One that cannot start
/// (no native library in this build) is left out, and its kind shows the
/// placeholder.
Future<Map<MediaKind, Decoder>> _decoders(
  MpxDecoderContext context,
  FrameCache cache,
) async {
  final decoders = <MediaKind, Decoder>{};
  // Teardowns run last first: the listener goes before the cache.
  context.onDispose(cache.dispose);
  final quota = context.registeredQuotas[BytesQuota.lottieFrames.name];
  if (quota != null) {
    void report() => quota.reportUsage(cache.diskBytes.value);
    cache.diskBytes.addListener(report);
    context.onDispose(() => cache.diskBytes.removeListener(report));
    await cache.scan();
  }
  try {
    final engine = await IsolateLottieEngine.spawn();
    final memory = NativeFramePageMemory();
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

/// Serves `https://media.example/<file>` from `assets/media/<file>`,
/// answering a single-range request with its bytes as a CDN would.
final class _BundleOrigin extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final Uint8List bytes;
    try {
      final data = await rootBundle.load(
        'assets/media/${request.url.pathSegments.last}',
      );
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on Object {
      // Not in the bundle: the origin has no such file.
      return http.StreamedResponse(const Stream.empty(), 404, request: request);
    }
    final range = RegExp(
      r'^bytes=(\d+)-(\d*)$',
    ).firstMatch(request.headers['range'] ?? '');
    if (range == null || int.parse(range.group(1)!) >= bytes.length) {
      return http.StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length,
        headers: {'accept-ranges': 'bytes'},
        request: request,
      );
    }
    final start = int.parse(range.group(1)!);
    final last = switch (int.tryParse(range.group(2)!)) {
      final end? when end < bytes.length => end,
      _ => bytes.length - 1,
    };
    return http.StreamedResponse(
      Stream.value(bytes.sublist(start, last + 1)),
      206,
      contentLength: last - start + 1,
      headers: {
        'accept-ranges': 'bytes',
        'content-range': 'bytes $start-$last/${bytes.length}',
      },
      request: request,
    );
  }
}

/// The example's media drawn by the stack's asset cache, opening in the
/// fullscreen viewer with save and share; a feed list gated by the device
/// signals; and the signals themselves.
class MediaApp extends StatefulWidget {
  const MediaApp({required this.stack, this.players, super.key});

  final MpxStack stack;

  /// The players the viewer plays videos with sound on.
  final PlayerPool? players;

  @override
  State<MediaApp> createState() => _MediaAppState();
}

class _MediaAppState extends State<MediaApp> {
  final ListGallery _gallery = ListGallery([
    for (final (key, kind, _, _) in _media)
      GalleryItem(
        key,
        // The silent video loop, the WebP and the Lottie all loop muted on
        // the software path, as animations do in the viewer.
        kind: switch (kind) {
          MediaKind.still => GalleryMediaKind.photo,
          _ when key == _soundClip => GalleryMediaKind.video,
          _ => GalleryMediaKind.animation,
        },
      ),
  ]);

  @override
  void dispose() {
    _gallery.dispose();
    widget.players?.dispose();
    widget.stack.dispose();
    super.dispose();
  }

  // The platform's reference viewer, opening from the tile's `ViewerOrigin`
  // through the closest `ViewerOriginScope`: no bridge to write.
  void _open(BuildContext context, int index) => MediaViewer.show(
    context,
    source: _gallery,
    initialIndex: index,
    players: widget.players,
    onFullscreenChanged: (on) => setWindowFullscreen(fullscreen: on),
    chrome: ViewerChrome(
      title: (context, index, item) => Text(_media[index].$4),
      openFile: cachedFiles(widget.stack),
      actions: (index, item) =>
          saveAndShare(context, (key) => _fileOf(key) ?? key.encoded),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final signals = widget.stack.signals;
    return MaterialApp(
      home: AssetCacheProvider(
        scope: widget.stack.scope,
        child: Scaffold(
          appBar: AppBar(title: const Text('mpx')),
          body: Builder(
            builder: (context) => SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ViewerOriginScope(
                    child: GridView.extent(
                      maxCrossAxisExtent: 180,
                      childAspectRatio: 160 / 190,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (final (index, (key, kind, _, label))
                            in _media.indexed)
                          Builder(
                            builder: (context) => GestureDetector(
                              onTap: () => _open(context, index),
                              child: _MediaTile(
                                index: index,
                                content: key,
                                plays: kind != MediaKind.still,
                                label: label,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  ListTile(
                    title: const Text('Feed list'),
                    subtitle: const Text('Visible clips play muted'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AssetCacheProvider(
                          scope: widget.stack.scope,
                          child: FeedPage(
                            signals: signals,
                            clips: [_media[1].$1, _media[3].$1],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
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
        ),
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    required this.index,
    required this.content,
    required this.plays,
    required this.label,
  });

  /// The tile's gallery index: its picture is the viewer's origin.
  final int index;

  static const double _extent = 160;

  /// The picture's corners, as the tile draws them and declares them to the
  /// viewer.
  static const double _radius = 12;

  // The picture shown whole, its own corners rounded: what the origin
  // declares (contain, radius 12) is what the tile shows.
  static const AssetProfile _profile = AssetProfile(
    animate: true,
    cornerRadius: _radius,
  );

  final MediaKey content;

  /// Whether the content plays: it then binds the one spec every surface
  /// that plays it binds, so the viewer draws this tile's own playback.
  final bool plays;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ViewerOrigin(
        index: index,
        borderRadius: const BorderRadius.all(Radius.circular(_radius)),
        // The tile shows the picture whole, letterboxed in its square.
        fit: BoxFit.contain,
        child: ContentView(
          content: content,
          preset: plays
              ? AssetPresets.animation(
                  size: const Size.square(_extent),
                  profile: _profile,
                )
              : AssetPresets.square(
                  extent: _extent,
                  devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                  profile: _profile,
                ),
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
