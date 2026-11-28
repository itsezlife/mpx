import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx/native.dart';
import 'package:mpx_core/frame_pool.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/feed_page.dart';
import 'package:mpx_example/gallery.dart';
import 'package:mpx_example/journal/data/diagnostics_journal.dart';
import 'package:mpx_example/journal/data/environment_specific/host_environment.dart'
    as environment_specific;
import 'package:mpx_example/journal/data/journal_host.dart';
import 'package:mpx_example/journal/view/journal_page.dart';
import 'package:mpx_example/lab/corpus.dart';
import 'package:mpx_example/lab/lab.dart';
import 'package:mpx_example/lab/lab_coverage.dart';
import 'package:mpx_example/lab/lab_viewer.dart';
import 'package:mpx_example/lab/stress_feed.dart';
import 'package:mpx_example/loading_demo.dart';
import 'package:mpx_example/picker_page.dart';
import 'package:mpx_example/svg_demo.dart';
import 'package:mpx_example/transfers/transfers_demo.dart';
import 'package:mpx_example/transfers/transfers_page.dart';
import 'package:mpx_example/transfers/transfers_root.dart';
import 'package:mpx_example/transfers/transfers_wiring.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_lottie/mpx_lottie.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/native.dart';
import 'package:mpx_svg/mpx_svg.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';

/// The media the example shows: a key, how it renders, the file the origin
/// serves for it, and a label. A lab build on a device corpus shows the
/// corpus instead.
List<(MediaKey, MediaKind, String, String)> _media = _bundledMedia;

const List<(MediaKey, MediaKind, String, String)> _bundledMedia = [
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

/// The keys whose viewer page plays with sound on the platform player.
Set<MediaKey> _withSound = {const MediaKey.remote('clip')};

/// Where the origin serves [file]: the lab's loopback origin when it runs,
/// else the example's bundle origin.
Uri _urlOf(String file) =>
    (kMpxLab ? Lab.urlOf(file) : null) ??
    Uri.parse('https://media.example/$file');

String _mimeOf(String file) => switch (file.split('.').last.toLowerCase()) {
  'webm' => 'video/webm',
  'mkv' => 'video/x-matroska',
  'mov' => 'video/quicktime',
  _ => 'video/mp4',
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // First, so the previous run's tail and everything below are in it.
  final journal = await JournalHost.start(name: 'mpx_example_journal');
  // Beside the journal: on Android the `cache` folder, which an app update
  // leaves alone, so the transfer journal below the bytes cache outlives an
  // install over the top.
  final cacheDirectory = environment_specific.$journalDirectoryPath(
    'mpx_example',
  );
  final framesDirectory = environment_specific.$journalDirectoryPath(
    'mpx_example_frames',
  );
  // The transfers demo: its settings (kept across runs), the debug panel's
  // network cut, and the development server it sends to.
  final transfers = TransfersWiring.load(cacheDirectory: cacheDirectory);
  if (kMpxLab) {
    await Lab.start(cacheDirs: [cacheDirectory, framesDirectory]);
    if (Lab.corpus != null && !Lab.homeShowsCorpus) {
      _media = const [];
      _withSound = const {};
    } else if (Lab.corpus case final corpus?) {
      _media = [
        for (final e in corpus.entries)
          (MediaKey.remote('corpus-${e.file}'), e.kind.media, e.file, e.file),
      ];
      _withSound = {
        for (final e in corpus.entries)
          if (e.kind == CorpusKind.video) MediaKey.remote('corpus-${e.file}'),
      };
    }
  }
  // Rendered Lottie frames keep a folder of their own, counted against the
  // store's one budget as its `lottie_frames` quota: no sweep of our own.
  final frames = FrameCache(
    directoryPath: framesDirectory,
    diskBudgetBytes: null,
  );
  // The process's one native reader, over the stack's ranged resources:
  // the software decoder streams clips through it (index and first stretch
  // first, then what plays, never waiting on a decode worker), and the
  // players read their sources through it.
  NativeRangedReaders? readers;
  // The device's signals, read by the stack and by the auto-download policy
  // (which tiles download by themselves on this network).
  final signals = DeviceSignals();
  final stack = await MpxStack.create(
    // The transfer engine over the stack's own fetcher and store, its
    // tracked transfers handed to the scope: cells with a status control
    // download as tracked jobs, and an upload's ring shows on its local key.
    // Its connectivity is the device's network signal, the scope's too.
    tracked: transfers.tracked(signals.network),
    resolver: transfers.resolver,
    signals: signals,
    autoDownload: LoadingDemo.policy(signals),
    // Where each key's bytes are. A real host maps its keys to its CDN.
    locate: (descriptor, part) => switch ((part, descriptor.thumbnail)) {
      // A corpus item's thumbnail, served beside it as a server would.
      (FetchPart.thumbnail, final ref?) => switch (Lab.thumbnailUrlOf(
        ref.value,
      )) {
        final url? => MediaLocation(url.toString()),
        null => null,
      },
      _ when transfers.locationOf(descriptor.key) != null =>
        transfers.locationOf(descriptor.key),
      _ => switch (_fileOf(descriptor.key)) {
        final file? => MediaLocation(_urlOf(file).toString()),
        null => switch (SvgDemo.urlOf(descriptor.key)) {
          final url? => MediaLocation(url),
          null => null,
        },
      },
    },
    cacheDirectory: cacheDirectory,
    registeredQuotas: {BytesQuota.lottieFrames: frames.evict},
    decoders: (context) => _decoders(context, frames),
    // A clip whose codec the software decoder was built without (AV1, HEVC)
    // still gets a first-frame still, drawn once by the platform.
    fallbackDecoders: {
      if (_hasPlatformStill) MediaKind.video: PlatformStillDecoder(),
      // An image that turns out to be SVG (the engine's codecs report it
      // unsupported) is drawn as one.
      MediaKind.still: SvgDecoder(),
    },
    // The example's origin answers from the app bundle so it runs offline; a
    // real host leaves `client` out and gets the network. A lab run on a
    // corpus takes the network, every request recorded.
    // The debug panel's network cut fails every request of this client,
    // which the transfer engine sends its parts through too.
    client:
        (kMpxLab ? Lab.httpClient() : null) ??
        HttpBytesClient(
          client: _BundleOrigin(),
          middlewares: transfers.middlewares,
        ),
    publisher: (ranged) => NativeRangedReaders.isAvailable
        ? NativeRangedContentPublisher(readers = NativeRangedReaders(ranged))
        : null,
  );
  // What the host knows of each item, as its server would say: the size
  // (the auto-download policy weighs it; a video or animation of unknown
  // size waits for a tap), and for a corpus item its preview and thumbnail.
  for (final (key, kind, file, _) in _media) {
    // A corpus item comes with what its server says: preview, thumbnail.
    if (Lab.corpus?.entryOf(file) case final entry?) {
      stack.pipeline.know(entry.descriptorOf(key));
      continue;
    }
    final size = await _bundledSize(file);
    stack.pipeline.know(
      MediaDescriptor(
        key: key,
        kind: kind,
        animated: kind != MediaKind.still,
        byteSize: size,
      ),
    );
  }
  SvgDemo.descriptors.forEach(stack.pipeline.know);
  final players = await _players(readers, stack.scope);
  if (kMpxLab) Lab.attach(stack, players);
  final demo = transfers.demo(stack);
  runApp(
    MediaApp(stack: stack, players: players, journal: journal, transfers: demo),
  );
}

/// The device's media library, one for the app: the picker shows it and
/// the players read its videos. Made on first use.
final PlatformMediaLibrary deviceLibrary = PlatformMediaLibrary();

/// The size of a bundled media [file], or null when the bundle has none
/// (a corpus file).
Future<int?> _bundledSize(String file) async {
  try {
    return (await rootBundle.load('assets/media/$file')).lengthInBytes;
  } on Object {
    return null;
  }
}

/// The platform player over the stack's cache: the viewer plays videos with
/// sound on it, reading their bytes through the cache's native reader. Null
/// where there is no native reader (the viewer then shows stills).
Future<PlayerPool?> _players(
  NativeRangedReaders? readers,
  AssetCacheScope scope,
) async {
  if (readers == null) return null;
  // The example logs the players' lifecycle, so a problem seen on a device
  // can be traced in its log.
  PlayerDiagnostics.enabled = true;
  // Which content each source the players read is, so the bytes they pull
  // count as that content's download on every surface of it.
  final contentOf = <BytesCacheKey, MediaKey>{};
  final backend = NativePlayerBackend(
    readers: readers,
    // A library video (the picker's viewer) plays its file in place.
    sourcesOf: (key) => LibraryFetcher.handles(key)
        ? LibraryPlayerSources.of(deviceLibrary, key)
        : switch (_fileOf(key)) {
            final file? => [
              PlayerSource(
                RangedRequest(
                  url: _urlOf(file),
                  // The content's own entry: the player and the software decoder
                  // read one sparse file, so a clip is downloaded once.
                  cacheKey: contentOf.keyOf(key),
                ),
                mimeType: _mimeOf(file),
              ),
            ],
            null => const <PlayerSource>[],
          },
    watchSource: (source) => switch (contentOf[source.cacheKey]) {
      final key? => scope.openOutsideReader(key),
      null => null,
    },
  );
  // Prepared players only where the device can hold them.
  return PlayerPool(backend: backend, budget: (await backend.device).budget);
}

extension on Map<BytesCacheKey, MediaKey> {
  // The bytes cache key of [key]'s content, remembered as [key]'s.
  BytesCacheKey keyOf(MediaKey key) {
    final cacheKey = BytesCacheFetcher.cacheKeyOf(key, FetchPart.content);
    this[cacheKey] = key;
    return cacheKey;
  }
}

String? _fileOf(MediaKey key) =>
    [
      for (final (known, _, file, _) in _media)
        if (known == key) file,
    ].firstOrNull ??
    (kMpxLab ? StressItems.fileOf(key) : null);

/// Whether the platform draws stills of video (`PlatformStillDecoder`):
/// Android, iOS and macOS.
bool get _hasPlatformStill =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      _ => false,
    };

/// The heavy decoders, each over its own native engine. One that cannot start
/// (no native library in this build) is left out, and its kind shows the
/// placeholder.
Future<Map<MediaKind, Decoder>> _decoders(
  MpxDecoderContext context,
  FrameCache cache,
) async {
  final decoders = <MediaKind, Decoder>{
    // SVG, held to the standard limits for content from anywhere.
    MediaKind.vectorImage: SvgDecoder(),
  };
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
    if (kMpxLab) Lab.wireLottie(scheduler);
    decoders[MediaKind.vectorAnimation] = LottieDecoder(
      engine: engine,
      scheduler: scheduler,
      cache: cache,
    );
  } on Object catch (reason) {
    debugPrint('Lottie is off: $reason');
  }
  try {
    final worker = await IsolateVideoEngine.spawn();
    final engine = kMpxLab ? LabCoverage.count(worker) : worker;
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
    if (kMpxLab) Lab.wireVideo(scheduler);
    // A clip that does not open says why in the log, instead of staying on
    // its placeholder in silence.
    VideoDecoder.logFailures = true;
    VideoFrameScheduler.logPlayback = true;
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
/// answering a single-range request with its bytes as a CDN would. Any other
/// host goes out to the network (the SVG demo's public file).
final class _BundleOrigin extends http.BaseClient {
  final http.Client _network = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host != 'media.example') return _network.send(request);
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
  const MediaApp({
    required this.stack,
    required this.journal,
    required this.transfers,
    this.players,
    super.key,
  });

  final MpxStack stack;

  /// The transfers demo and its debug panel.
  final TransfersDemo transfers;

  /// The journal the Logs screen shows.
  final DiagnosticsJournal journal;

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
          _ when _withSound.contains(key) => GalleryMediaKind.video,
          _ => GalleryMediaKind.animation,
        },
      ),
  ]);

  final GlobalKey<NavigatorState> _navigator = kMpxLab
      ? Lab.navigatorKey
      : GlobalKey<NavigatorState>();

  @override
  void dispose() {
    widget.transfers.dispose();
    widget.transfers.root.dispose();
    _gallery.dispose();
    widget.players?.dispose();
    widget.stack.dispose();
    super.dispose();
  }

  // The platform's standard viewer, opening from the tile's `ViewerOrigin`
  // through the closest `ViewerOriginScope`: no bridge to write.
  void _open(BuildContext context, int index) => MediaViewer.show(
    context,
    source: _gallery,
    initialIndex: index,
    players: widget.players,
    controller: LabViewer.controller('home'),
    policy: LabViewer.policy(context),
    onBackdropScale: LabViewer.onBackdropScale,
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
      navigatorKey: _navigator,
      navigatorObservers: [if (kMpxLab) Lab.observer],
      builder: (context, child) => TransfersQuitGuard(
        transfers: widget.transfers.transfers,
        navigatorKey: _navigator,
        child: kMpxLab ? Lab.wrap(context, child) : child!,
      ),
      home: AssetCacheProvider(
        scope: widget.stack.scope,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('mpx'),
            // The lab's stress feed, in the bar so the page below keeps
            // its layout.
            actions: [
              if (kMpxLab)
                const IconButton(
                  tooltip: 'Stress feed (lab)',
                  icon: Icon(Icons.speed),
                  onPressed: Lab.openStress,
                ),
              Builder(
                builder: (context) => IconButton(
                  tooltip: 'Logs',
                  icon: const Icon(Icons.article_outlined),
                  onPressed: () => Navigator.of(
                    context,
                  ).push(JournalPage.route(journal: widget.journal)),
                ),
              ),
            ],
          ),
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
                              // The picture paints without taking hits: the whole tile does.
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _open(context, index),
                              child: _MediaTile(
                                index: index,
                                content: key,
                                plays: kind != MediaKind.still,
                                label: label,
                                // Every other tile waits for a tap on a
                                // fresh install: its download control and
                                // size show over the stand-in.
                                downloadContext: index.isOdd
                                    ? LoadingDemo.manual
                                    : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  const SvgDemoRow(),
                  const SizedBox(height: 24),
                  ListTile(
                    title: const Text('Feed list'),
                    subtitle: const Text('Visible clips play muted'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        settings: const RouteSettings(name: 'feed'),
                        builder: (_) => AssetCacheProvider(
                          scope: widget.stack.scope,
                          child: FeedPage(
                            signals: signals,
                            clips: [
                              for (final (key, kind, _, _) in _media)
                                if (kind != MediaKind.still) key,
                            ].take(2).toList(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ListTile(
                    title: const Text('Transfers'),
                    subtitle: const Text(
                      'Publish jobs, tracked downloads, debug panel',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      TransfersPage.route(
                        demo: widget.transfers,
                        journal: widget.journal,
                        pick: DemoPick.fromFileDialog,
                        wrap: (page) => AssetCacheProvider(
                          scope: widget.stack.scope,
                          child: page,
                        ),
                      ),
                    ),
                  ),
                  // The device library is on Android and iOS only.
                  if (Platform.isAndroid || Platform.isIOS)
                    ListTile(
                      title: const Text('Media picker'),
                      subtitle: const Text('Library, camera, selection'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          settings: const RouteSettings(name: 'picker'),
                          builder: (_) => PickerPage(
                            library: deviceLibrary,
                            store: widget.stack.store,
                            clock: widget.stack.scope.clock,
                            players: widget.players,
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
    this.downloadContext,
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

  /// The tile's auto-download tag.
  final AutoDownloadContext? downloadContext;

  @override
  Widget build(BuildContext context) {
    final preset = plays
        ? AssetPresets.animation(
            size: const Size.square(_extent),
            profile: _profile,
          )
        : AssetPresets.square(
            extent: _extent,
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            profile: _profile,
          );
    LabViewer.card('home', index, content, preset.spec);
    // The square takes what the grid cell leaves under the label, so a
    // narrow cell (three columns on a large phone) never overflows.
    return Column(
      children: [
        Expanded(
          child: AspectRatio(
            aspectRatio: 1,
            child: ViewerOrigin(
              index: index,
              borderRadius: const BorderRadius.all(Radius.circular(_radius)),
              // The tile shows the picture whole, letterboxed in its square.
              fit: BoxFit.contain,
              child: AssetView(
                content: content,
                preset: preset,
                downloadContext: downloadContext,
                status: const MediaStatusMode.control(),
                badge: true,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          downloadContext == null ? label : '$label (tap to load)',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
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
