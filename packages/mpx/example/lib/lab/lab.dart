import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming, PlatformDispatcher;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/lab/corpus.dart';
import 'package:mpx_example/lab/lab_coverage.dart';
import 'package:mpx_example/lab/lab_net.dart';
import 'package:mpx_example/lab/pointer_tape.dart';
import 'package:mpx_example/lab/stress_feed.dart';
import 'package:mpx_lottie/mpx_lottie.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';

/// Whether this build carries the performance lab:
/// `--dart-define=MPX_LAB=true`. Every lab call site is behind it, so a
/// regular build compiles the lab out.
const bool kMpxLab = bool.fromEnvironment('MPX_LAB');

/// The performance lab: switches and commands over
/// `adb shell am broadcast -a lab.SET --es key <key> --es value <value>`,
/// a frame log in logcat (`LAB` lines), a content position mark per frame
/// (`LABy`), semantic marks (`LABe`), and the pointer tape.
///
/// See `tool/lab/README.md` for the keys and the marks.
abstract final class Lab {
  static const _channel = MethodChannel('mpx_example/lab');

  /// Items in the stress feed, read as it opens.
  static final items = ValueNotifier<int>(50);

  /// Media kinds in the stress feed, read as it opens.
  static final kinds = ValueNotifier<Set<CorpusKind>>(
    CorpusKind.values.toSet(),
  );

  /// Whether every stress item has a key of its own (its own bytes, decode
  /// and playback); off, the items of one kind share one key. Read as the
  /// feed opens.
  static final distinct = ValueNotifier<bool>(true);

  /// Whether playing Lottie and video may take platform textures.
  static final textures = ValueNotifier<bool>(true);

  /// `GestureBinding.resamplingEnabled`.
  static final resampling = ValueNotifier<bool>(false);

  /// `VideoFrameScheduler.maxAdvancing`; null keeps the scheduler's.
  static final videoCap = ValueNotifier<int?>(null);

  /// Where corpus media comes from: `net`, the public entries from their
  /// internet URLs and the folder's own files from the loopback origin;
  /// `local`, every entry with a file in the folder from the loopback
  /// origin (throttled by the two switches below). Read at start
  /// (`lab_origin`).
  static String originMode = 'net';

  /// Every request the stack sends in a corpus run, for the run's network
  /// numbers.
  static NetRecorder? net;

  /// The loopback origin's bandwidth in kilobits per second; 0 for none.
  static final throttleKbps = ValueNotifier<int>(0);

  /// The loopback origin's delay before each response's first byte.
  static final latencyMs = ValueNotifier<int>(0);

  /// Whether this process started with its caches wiped (`lab_cold`).
  static bool cold = false;

  /// The media of this run: the device's corpus folder when it holds a
  /// manifest (`lab_corpus off` ignores it), else null and the bundled
  /// fixtures.
  static Corpus? corpus;

  /// The origin serving [corpus] over loopback HTTP, while there is one.
  static LoopbackOrigin? origin;

  /// The example's bundled files, as a corpus without the folder.
  static const List<CorpusEntry> bundled = [
    CorpusEntry(file: 'still.png', kind: CorpusKind.still),
    CorpusEntry(file: 'counter.webp', kind: CorpusKind.animated),
    CorpusEntry(file: 'square.json', kind: CorpusKind.lottie),
    CorpusEntry(file: 'loop.webm', kind: CorpusKind.loop),
    CorpusEntry(file: 'clip.mp4', kind: CorpusKind.video),
  ];

  /// The files the stress feed and the home page show.
  static List<CorpusEntry> get sources => corpus?.entries ?? bundled;

  /// Where the corpus [file] is fetched from; null without a corpus.
  static Uri? urlOf(String file) {
    final found = corpus;
    final entry = found?.entryOf(file);
    if (found == null || entry == null) return null;
    final local = Corpus.hasFile(found.directory, entry);
    final remote = entry.url;
    if (remote != null && (originMode != 'local' || !local)) return remote;
    return origin?.urlOf(file);
  }

  /// The stack's client for a corpus run: the network with the stack's own
  /// middlewares, every request recorded. Null without a corpus.
  static HttpBytesClient? httpClient() {
    if (corpus == null) return null;
    final recorder = net = NetRecorder(http.Client());
    return HttpBytesClient(
      client: recorder,
      middlewares: [
        HttpBytesRetryMiddleware().call,
        const HttpBytesTimeoutMiddleware().call,
        const HttpBytesConditionalMiddleware().call,
      ],
      // As the stack's default client: media bodies stay on the transfer
      // worker, which reports each transfer for the network numbers.
      transfers: HttpBytesTransfers(onTransfer: recorder.recordTransfer),
    );
  }

  static void _logNet() {
    final recorder = net;
    if (recorder == null) return;
    recorder.report(entries: corpus!.entries.length).forEach(_log);
  }

  /// The navigator the lab opens and closes pages on.
  static final navigatorKey = GlobalKey<NavigatorState>();

  static String? _filesDir;
  static MpxStack? _stack;
  static PlayerPool? _players;
  static bool _installed = false;

  /// The cache scope of the stack, once attached.
  static AssetCacheScope? get scope => _stack?.scope;

  /// Reads the start switches (`am start ... --es lab_<key> <value>`) and,
  /// with `lab_cold true`, deletes [cacheDirs] before anything opens them,
  /// so the process starts with no media cached anywhere. Call before the
  /// stack is created.
  static Future<void> start({required List<String> cacheDirs}) async {
    final reply = await _channel.invokeMapMethod<String, Object?>('install');
    _filesDir = reply?['filesDir'] as String?;
    final extras = (reply?['extras'] as Map<Object?, Object?>? ?? const {}).map(
      (k, v) => MapEntry('$k', '$v'),
    );
    cold = extras['cold'] == 'true';
    if (cold) {
      for (final dir in cacheDirs) {
        final folder = Directory(dir);
        if (folder.existsSync()) folder.deleteSync(recursive: true);
      }
    }
    for (final MapEntry(:key, :value) in extras.entries) {
      if (!const {'cold', 'open', 'origin', 'corpus'}.contains(key)) {
        _setSwitch(key, value);
      }
    }
    _startRoute = extras['open'];
    originMode = extras['origin'] == 'local' ? 'local' : 'net';
    if (extras['corpus'] != 'off' && _filesDir != null) {
      final found = corpus = await Corpus.load('$_filesDir/corpus');
      if (found != null) {
        final served = origin = await LoopbackOrigin.serve(found.directory);
        void throttle() {
          served
            ..bytesPerSecond = throttleKbps.value > 0
                ? throttleKbps.value * 1000 ~/ 8
                : null
            ..latency = Duration(milliseconds: latencyMs.value);
        }

        throttle();
        throttleKbps.addListener(throttle);
        latencyMs.addListener(throttle);
      }
    }
  }

  static void _logCorpus() {
    final found = corpus;
    if (found == null) {
      _log('corpus bundled entries=${bundled.length}');
      return;
    }
    _log(
      'corpus fingerprint=${found.fingerprint} entries=${found.entries.length} '
      'origin=$originMode loopback=${origin?.urlOf('')}',
    );
    for (final entry in found.entries) {
      _log('corpus ${entry.describe()}');
    }
  }

  static String? _startRoute;

  /// Wires the lab to [stack] and [players]: the tape, the frame log, the
  /// broadcast commands. Call after the binding exists, before `runApp`.
  static void attach(MpxStack stack, PlayerPool? players) {
    if (_installed) return;
    _installed = true;
    _stack = stack;
    _players = players;
    PointerTape.install();
    resampling.addListener(() {
      GestureBinding.instance.resamplingEnabled = resampling.value;
    });
    GestureBinding.instance.resamplingEnabled = resampling.value;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'set') return;
      final args = (call.arguments as Map<Object?, Object?>).map(
        (k, v) => MapEntry('$k', '$v'),
      );
      await _command(args['key'] ?? '', args['value'] ?? '', args['name']);
    });
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _logCorpus();
      _log('ready cold=$cold ${_switches()}');
      if (_startRoute == 'stress') openStress();
    });
  }

  /// Takes the Lottie scheduler under the `textures` switch.
  static void wireLottie(LottieFrameScheduler scheduler) {
    void apply() => scheduler.texturesEnabled = textures.value;
    apply();
    textures.addListener(apply);
  }

  /// Takes the video scheduler under the `textures` and `video_cap`
  /// switches.
  static void wireVideo(VideoFrameScheduler scheduler) {
    final initialCap = scheduler.maxAdvancing;
    void apply() {
      scheduler
        ..texturesEnabled = textures.value
        ..maxAdvancing = videoCap.value ?? initialCap;
    }

    apply();
    textures.addListener(apply);
    videoCap.addListener(apply);
  }

  static String _switches() =>
      'items=${items.value} kinds=${kinds.value.map((k) => k.name).join(',')} '
      'distinct=${distinct.value} textures=${textures.value} '
      'resampling=${resampling.value} videoCap=${videoCap.value ?? 'default'} '
      'throttleKbps=${throttleKbps.value} latencyMs=${latencyMs.value}';

  static void _setSwitch(String key, String value) {
    bool? on() => switch (value) {
      'true' || 'on' || '1' => true,
      'false' || 'off' || '0' => false,
      _ => null,
    };
    switch (key) {
      case 'items':
        final n = int.tryParse(value);
        if (n == null || n < 1) return _log('items: a number from 1');
        items.value = n;
      case 'kinds':
        kinds.value = parseKinds(value);
      case 'distinct' || 'textures' || 'resampling':
        final v = on();
        if (v == null) return _log('$key: true or false');
        switch (key) {
          case 'distinct':
            distinct.value = v;
          case 'textures':
            textures.value = v;
          default:
            resampling.value = v;
        }
      case 'throttle_kbps' || 'latency_ms':
        final n = int.tryParse(value);
        if (n == null || n < 0) return _log('$key: a number from 0');
        (key == 'throttle_kbps' ? throttleKbps : latencyMs).value = n;
      case 'video_cap':
        final n = int.tryParse(value);
        videoCap.value = n == null || n < 1 ? null : n;
      default:
        return _log('unknown key $key');
    }
    _log('switch $key=$value');
  }

  static Future<void> _command(String key, String value, String? name) async {
    final tape = name ?? 'tape';
    switch (key) {
      case 'open':
        openStress();
      case 'home':
        navigatorKey.currentState?.popUntil((route) => route.isFirst);
        _log('home');
      case 'jump':
        final index = int.tryParse(value);
        if (_feed case (_, _, final scroll, final extent)? when index != null) {
          scroll.jumpTo(index * extent);
          _log('jump $index');
        }
      case 'state':
        _log('state route=$_top ${_switches()}');
      case 'net':
        _logNet();
      case 'record' when value == 'true':
        PointerTape.start(_top);
        LabCoverage.start();
        _log('tape record start $tape from $_top');
      case 'record':
        final n = await PointerTape.stop(_filesDir!, tape);
        _log(LabCoverage.stop());
        _log('tape saved $tape rows=$n');
      case 'replay':
        await _replay(tape);
      default:
        _setSwitch(key, value);
    }
  }

  static Future<void> _replay(String name) async {
    final Tape tape;
    try {
      tape = await PointerTape.load(_filesDir!, name, _top);
    } on TapeRefused catch (reason) {
      _log('tape replay refused $name: $reason');
      return;
    }
    _log('tape replay start $name rows=${tape.rows.length}');
    _replayFrames = [];
    LabCoverage.start();
    final n = await PointerTape.replay(tape);
    // Timings arrive in batches; let the last one land.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    _logReplaySummary(_replayFrames!);
    _log(LabCoverage.stop());
    _replayFrames = null;
    _logNet();
    _log('tape replay done $name rows=$n');
  }

  // --- Pages ---------------------------------------------------------------

  /// Opens the stress feed on top of the home page, with the switches now.
  static void openStress() {
    final navigator = navigatorKey.currentState;
    final stack = _stack;
    if (navigator == null || stack == null) return;
    if (!sources.any((s) => kinds.value.contains(s.kind))) {
      return _log(
        'open refused: no source of the kinds '
        '${kinds.value.map((k) => k.name).join(',')}',
      );
    }
    final feed = StressItems(
      count: items.value,
      sources: sources,
      kinds: kinds.value,
      distinct: distinct.value,
    )..know(stack);
    LabCoverage.watch(stack.scope, feed);
    navigator
      ..popUntil((route) => route.isFirst)
      ..push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'stress'),
          builder: (_) => AssetCacheProvider(
            scope: stack.scope,
            child: StressFeedPage(
              items: feed,
              signals: stack.signals,
              players: _players,
            ),
          ),
        ),
      );
  }

  static (Object, StressItems, ScrollController, double)? _feed;

  /// The stress feed's page [owner] opened with [feed]: marks it and the
  /// first frame any of its first items has a picture.
  static void feedOpened(
    Object owner,
    StressItems feed,
    ScrollController scroll,
    double extent,
  ) {
    if (!kMpxLab) return;
    _feed = (owner, feed, scroll, extent);
    event('feed open $feed cold=$cold');
    final watched = [
      for (var i = 0; i < feed.count && i < 6; i++) feed.keyAt(i),
    ];
    final timeout = Stopwatch()..start();
    void check(Duration _) {
      if (_feed?.$1 != owner) return;
      if (watched.any((key) => scope?.pictureSizeOf(key) != null)) {
        event('feed first-content');
      } else if (timeout.elapsed > const Duration(seconds: 10)) {
        event('feed no-content');
      } else {
        SchedulerBinding.instance.addPostFrameCallback(check);
      }
    }

    SchedulerBinding.instance.addPostFrameCallback(check);
  }

  /// The stress feed's page [owner] closed.
  static void feedClosed(Object owner) {
    if (!kMpxLab) return;
    if (_feed?.$1 == owner) _feed = null;
    event('feed closed');
  }

  // --- Marks ---------------------------------------------------------------

  /// Marks [what] as a `LABe <what> f=<frame>` slice and logs it, the frame
  /// being the engine's current frame number (`FrameTiming.frameNumber`).
  static void event(String what) {
    if (!kMpxLab) return;
    final frame = PlatformDispatcher.instance.frameData.frameNumber;
    Timeline.timeSync('LABe $what f=$frame', () {});
    _log('event $what f=$frame');
  }

  static final List<String> _routes = [];
  static String get _top => _routes.lastOrNull ?? 'none';

  /// Marks route pushes and pops (`LABe route push <name>`); an unnamed
  /// route is the viewer.
  static final NavigatorObserver observer = _RouteMarks();

  /// Wraps the app's navigator with the scroll marks: `LABy <px>` on every
  /// vertical scroll update, `scroll start|end <route>` around each scroll.
  static Widget wrap(BuildContext context, Widget? child) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: child ?? const SizedBox.shrink(),
      );

  static bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    switch (n) {
      case ScrollStartNotification():
        event('scroll start $_top at=${n.metrics.pixels.round()}');
      case ScrollUpdateNotification():
        Timeline.timeSync('LABy ${n.metrics.pixels.toStringAsFixed(2)}', () {});
      case ScrollEndNotification():
        event('scroll end $_top at=${n.metrics.pixels.round()}');
      default:
    }
    return false;
  }

  // --- Frame log -------------------------------------------------------------

  static int get _budgetMicros {
    final hz =
        PlatformDispatcher.instance.displays.firstOrNull?.refreshRate ?? 60;
    return (1e6 / hz).round();
  }

  static final _burst = <FrameTiming>[];
  static Timer? _quiet;
  static List<FrameTiming>? _replayFrames;

  static void _onTimings(List<FrameTiming> timings) {
    _replayFrames?.addAll(timings);
    final budget = _budgetMicros;
    for (final t in timings) {
      _burst.add(t);
      if (t.totalSpan.inMicroseconds > budget) {
        _log(
          'slow #${t.frameNumber} span=${_ms(t.totalSpan.inMicroseconds)} '
          'at=${_ms(t.timestampInMicroseconds(FramePhase.vsyncStart))} '
          'vsync=${_ms(t.vsyncOverhead.inMicroseconds)} '
          'build=${_ms(t.buildDuration.inMicroseconds)} '
          'raster=${_ms(t.rasterDuration.inMicroseconds)} '
          'queue=${_ms(t.timestampInMicroseconds(FramePhase.rasterStart) - t.timestampInMicroseconds(FramePhase.buildFinish))}',
        );
      }
    }
    _quiet?.cancel();
    _quiet = Timer(const Duration(milliseconds: 400), _flushBurst);
  }

  static String _quantiles(List<int> sorted) =>
      '${_ms(_p(sorted, .5))}/${_ms(_p(sorted, .9))}/'
      '${_ms(_p(sorted, .99))}/${_ms(sorted.last)}';

  static void _logReplaySummary(List<FrameTiming> frames) {
    if (frames.isEmpty) return _log('summary frames=0');
    final budget = _budgetMicros;
    final build = [for (final t in frames) t.buildDuration.inMicroseconds]
      ..sort();
    final raster = [for (final t in frames) t.rasterDuration.inMicroseconds]
      ..sort();
    final span = [for (final t in frames) t.totalSpan.inMicroseconds]..sort();
    _log(
      'summary frames=${frames.length} '
      'build p50/p90/p99/max=${_quantiles(build)} '
      'raster p50/p90/p99/max=${_quantiles(raster)} '
      'span p50/p90/p99/max=${_quantiles(span)} '
      'spanOver=${span.where((s) => s > budget).length} '
      'spanOver2x=${span.where((s) => s > 2 * budget).length} '
      'vsyncGaps=${_gaps(frames, budget)}',
    );
  }

  /// Gaps between consecutive vsyncs over 1.5 budgets (under 100 ms, so an
  /// idle stretch does not count): refreshes the display repeated.
  static int _gaps(List<FrameTiming> frames, int budget) {
    var gaps = 0;
    for (var i = 1; i < frames.length; i++) {
      final dt =
          frames[i].timestampInMicroseconds(FramePhase.vsyncStart) -
          frames[i - 1].timestampInMicroseconds(FramePhase.vsyncStart);
      if (dt > budget * 1.5 && dt < 100000) gaps++;
    }
    return gaps;
  }

  static void _flushBurst() {
    if (_burst.length < 10) {
      _burst.clear();
      return;
    }
    final budget = _budgetMicros;
    final spans = [for (final t in _burst) t.totalSpan.inMicroseconds]..sort();
    final builds = [for (final t in _burst) t.buildDuration.inMicroseconds]
      ..sort();
    final rasters = [for (final t in _burst) t.rasterDuration.inMicroseconds]
      ..sort();
    _log(
      'burst frames=${_burst.length} '
      'over=${spans.where((s) => s > budget).length} '
      'gaps=${_gaps(_burst, budget)} '
      'build p50/p99/max=${_ms(_p(builds, .5))}/${_ms(_p(builds, .99))}/${_ms(builds.last)} '
      'raster p50/p99/max=${_ms(_p(rasters, .5))}/${_ms(_p(rasters, .99))}/${_ms(rasters.last)} '
      'span p50/p99/max=${_ms(_p(spans, .5))}/${_ms(_p(spans, .99))}/${_ms(spans.last)}',
    );
    _burst.clear();
  }

  static int _p(List<int> sorted, double q) =>
      sorted[((sorted.length - 1) * q).round()];

  static String _ms(int micros) => (micros / 1000).toStringAsFixed(1);

  // Every line ends with the timeline's monotonic time in ms, the clock of
  // the trace's Dart marks and of `FrameTiming` (a slow line's `at=`).
  static void _log(String message) =>
      debugPrint('LAB $message @${(Timeline.now / 1000).toStringAsFixed(1)}');
}

final class _RouteMarks extends NavigatorObserver {
  static String _name(Route<dynamic> route) => switch (route.settings.name) {
    '/' => 'home',
    final String name => name,
    null => route.isFirst ? 'home' : 'viewer',
  };

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final name = _name(route);
    Lab._routes.add(name);
    Lab.event('route push $name');
    _markTransition(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (Lab._routes.isNotEmpty) Lab._routes.removeLast();
    Lab.event('route pop ${_name(route)}');
    _markTransition(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (Lab._routes.isNotEmpty) Lab._routes.removeLast();
    Lab.event('route remove ${_name(route)}');
  }

  /// Marks the route's transition progress on every frame it moves, as a
  /// `LABr <value>` slice, until it settles.
  static void _markTransition(Route<dynamic> route) {
    if (route is! ModalRoute<dynamic>) return;
    final animation = route.animation;
    if (animation == null) return;
    void mark() =>
        Timeline.timeSync('LABr ${animation.value.toStringAsFixed(4)}', () {});
    void settle(AnimationStatus status) {
      if (status.isAnimating) return;
      mark();
      animation
        ..removeListener(mark)
        ..removeStatusListener(settle);
    }

    animation
      ..addListener(mark)
      ..addStatusListener(settle);
  }
}
