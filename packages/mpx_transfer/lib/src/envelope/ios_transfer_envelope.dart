import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/envelope_op.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope_config.dart';

/// The [TransferEnvelope] of iOS, over the plugin's native part.
///
/// Starting it only arms it: nothing holds the process while the app is in
/// the foreground. When the app enters the background the native part
/// begins a background task at once (about 30 s, on every version). On
/// iOS 26 and later, with `system` jobs still inside, this side then asks
/// for a continued-processing task, whose progress the system shows in a
/// Live Activity with the config's title and text: after
/// [TransferEnvelopeConfig.submitAt]'s delay (10 s by default), or as soon
/// as the app resigns active (`TransferEnvelopeSubmitAt.onResignActive`).
/// While that task runs, the engine's progress is pushed to it every
/// [progressInterval]. Back in the foreground, whatever holds the process
/// is withdrawn and the envelope is armed again for the next background.
///
/// A refused submission keeps the background task, and when its time ends
/// the jobs pause (`TransferEnvelopeEvent.systemEnded`). The system ending a
/// continued-processing task is reported the same way: its expiry handler
/// runs both when the system stops it and when the user cancels it from the
/// Live Activity, and the two cannot be told apart, so the jobs pause rather
/// than being cancelled; nothing is deleted on a guess.
///
/// The policy lives here, so one Dart test pins it; the native part does
/// what must not wait for a round trip (the background task at the moment
/// of backgrounding) and what only it can (the task's registration and
/// submission, its progress, its handlers). It also writes each of its
/// events to `os_log` (subsystem `dev.mpx.transfer`, category `envelope`),
/// and while no Dart side is attached into a ring file in the app's
/// container of at most [nativeLogBytes]; the next start emits those
/// records with their original time and `native: true`, then
/// `envelope` `nativeMerged`.
///
/// One instance per process: it owns the plugin's channel. The host adds
/// the task identifier and the background mode the package README names.
final class IosTransferEnvelope implements TransferEnvelope {
  /// An envelope over the plugin's [channel]; a test passes its own, and
  /// [now] reads the time of [TransferEnvelopeEvent.changed]'s due time.
  IosTransferEnvelope({
    MethodChannel channel = defaultChannel,
    this.progressInterval = defaultProgressInterval,
    this.nativeLogBytes = defaultNativeLogBytes,
    DateTime Function()? now,
  }) : _channel = channel,
       _now = now ?? DateTime.now {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  /// The plugin's channel, both ways.
  static const MethodChannel defaultChannel = MethodChannel(
    'dev.mpx.transfer/envelope',
  );

  /// How often progress is pushed to a continued-processing task: 1 s.
  static const Duration defaultProgressInterval = Duration(seconds: 1);

  /// The largest the native ring file grows: 2 MiB.
  static const int defaultNativeLogBytes = 2 * 1024 * 1024;

  /// How often the engine's progress is pushed to a running
  /// continued-processing task, when it changed.
  final Duration progressInterval;

  /// The largest the native ring file grows before its oldest records are
  /// dropped.
  final int nativeLogBytes;

  final MethodChannel _channel;
  final DateTime Function() _now;
  final StreamController<TransferEnvelopeEvent> _events =
      StreamController.broadcast(sync: true);

  Future<_Attached>? _attaching;
  _Attached? _attached;

  /// The armed envelope's handle; null when none is.
  String? _handle;
  TransferEnvelopeConfig? _config;
  TransferEnvelopeProgress? _progress;

  /// What holds the process now; null while nothing does.
  TransferEnvelopeKind? _kind;
  _Submission _submission = _Submission.idle;
  Timer? _submitTimer;
  DateTime? _submitDueAt;
  Timer? _pushTimer;
  TransferEnvelopeProgress? _pushed;
  double _pushedFraction = 0;

  @override
  TransferEnvelopeStartRule get startRule => TransferEnvelopeStartRule.always;

  @override
  Stream<TransferEnvelopeEvent> get events => _events.stream;

  @override
  Future<Set<String>> live() async => (await _attach()).live;

  @override
  Future<TransferEnvelopeStart> start(
    TransferEnvelopeProgress progress,
    TransferEnvelopeConfig config,
  ) async {
    _progress = progress;
    _config = config;
    await _attach();
    final Map<String, Object?>? reply;
    try {
      reply = await _channel.invokeMapMethod<String, Object?>('arm');
    } on MissingPluginException {
      return const TransferEnvelopeStart.refused('platform');
    }
    final handle = reply?['handle'];
    if (handle is! String) return const TransferEnvelopeStart.refused('error');
    _arm(handle, config, progress);
    final foreground = reply?['foreground'] != false;
    _attached?.foreground = foreground;
    // The engine reports the kind this start answers; only later changes
    // are this side's to report.
    _kind = _kindOf(reply?['kind']);
    if (!foreground) _scheduleSubmission(resignedActive: true);
    return TransferEnvelopeStart.started(handle, kind: _kind);
  }

  @override
  void adopt(
    String handle,
    TransferEnvelopeProgress progress,
    TransferEnvelopeConfig config,
  ) {
    final attached = _attached;
    _arm(handle, config, progress);
    if (attached == null || !attached.live.contains(handle)) return;
    _kind = attached.kind;
    if (_kind == TransferEnvelopeKind.continuedProcessing) _startPushing();
    if (!attached.foreground) _scheduleSubmission(resignedActive: true);
  }

  @override
  void update(TransferEnvelopeProgress progress) => _progress = progress;

  @override
  void stop() {
    _disarm();
    unawaited(_invoke('disarm'));
  }

  // --- Native calls -----------------------------------------------------------

  Future<Object?> _onNativeCall(MethodCall call) async {
    final args = call.arguments is Map
        ? (call.arguments as Map).cast<String, Object?>()
        : const <String, Object?>{};
    switch (call.method) {
      case 'lifecycle':
        _onLifecycle(args);
      case 'held':
        if (args['handle'] != _handle) return null;
        _hold(_kindOf(args['kind']));
      // The seam event, shaped as on Android.
      case 'event' when args['type'] == 'systemEnded':
        if (args['handle'] != _handle || _handle == null) return null;
        _disarm();
        _events.add(
          TransferEnvelopeEvent.systemEnded(cause: _causeOf(args['cause'])),
        );
    }
    return null;
  }

  void _onLifecycle(Map<String, Object?> args) {
    final attached = _attached;
    switch (args['state']) {
      case 'resignActive':
        if (_handle == null) return;
        if (_config?.submitAt is TransferEnvelopeSubmitAt$OnResignActive) {
          _submitIfDue();
        }
      case 'background':
        attached?.foreground = false;
        if (_handle == null) return;
        if (args['refused'] case final String code) {
          MpxDiagnostics.current.emit(
            MpxEventLevel.warning,
            EnvelopeOp.refused,
            fields: () => {
              'kind': TransferEnvelopeKind.bgTask.name,
              'code': code,
            },
          );
        }
        _hold(_kindOf(args['kind']), changed: false);
        _scheduleSubmission(resignedActive: false);
        _changed();
      case 'active':
        attached?.foreground = true;
        _withdraw();
    }
  }

  // --- Policy -----------------------------------------------------------------

  void _arm(
    String handle,
    TransferEnvelopeConfig config,
    TransferEnvelopeProgress progress,
  ) {
    _handle = handle;
    _config = config;
    _progress = progress;
    _submission = _Submission.idle;
  }

  /// Arranges the continued-processing task after the app left the
  /// foreground, per the config's `submitAt`. [resignedActive] is true when
  /// the moment of resigning active already passed unseen (an envelope
  /// armed or adopted in the background), so `onResignActive` submits now.
  void _scheduleSubmission({required bool resignedActive}) {
    final attached = _attached;
    if (attached == null || !attached.continued) return;
    if (_submission != _Submission.idle || _submitTimer != null) return;
    switch (_config?.submitAt) {
      case TransferEnvelopeSubmitAt$AfterDelay(:final delay):
        _submitDueAt = _now().add(delay);
        _submitTimer = Timer(delay, () {
          _submitTimer = null;
          _submitDueAt = null;
          _submitIfDue();
        });
      case TransferEnvelopeSubmitAt$OnResignActive():
        if (resignedActive) _submitIfDue();
      case null:
        break;
    }
  }

  /// Submits the continued-processing task if `system` jobs remain and none
  /// was asked for since the app left the foreground.
  void _submitIfDue() {
    final handle = _handle;
    final config = _config;
    final attached = _attached;
    if (handle == null || config == null || attached == null) return;
    if (!attached.continued || _submission != _Submission.idle) return;
    final progress = _progress;
    if (progress == null || progress.jobs.isEmpty) return;
    _submitTimer?.cancel();
    _submitTimer = null;
    _submitDueAt = null;
    _submission = _Submission.asked;
    unawaited(_submit(handle, config, progress));
  }

  Future<void> _submit(
    String handle,
    TransferEnvelopeConfig config,
    TransferEnvelopeProgress progress,
  ) async {
    String? refusal;
    StackTrace? stackTrace;
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>('submit', {
        'handle': handle,
        'title': config.title,
        'subtitle': _subtitleOf(config, progress),
      });
      if (reply?['submitted'] != true) {
        refusal = switch (reply?['code']) {
          final String code => code,
          _ => 'refused',
        };
      }
    } on Object catch (_, trace) {
      // The error stays out of the event: a platform error may name app
      // state.
      refusal = 'error';
      stackTrace = trace;
    }
    if (refusal == null || handle != _handle) return;
    if (_submission != _Submission.asked) return;
    _submission = _Submission.refused;
    final code = refusal;
    MpxDiagnostics.current
      ..emit(
        MpxEventLevel.warning,
        EnvelopeOp.refused,
        fields: () => {
          'kind': TransferEnvelopeKind.continuedProcessing.name,
          'code': code,
        },
        stackTrace: stackTrace,
      )
      ..emit(
        MpxEventLevel.warning,
        EnvelopeOp.degraded,
        fields: () => {
          'from': TransferEnvelopeKind.continuedProcessing.name,
          'to': _kind?.name ?? 'inProcess',
          'why': 'submitFailed',
        },
      );
    _changed();
  }

  /// What holds the process became [kind].
  void _hold(TransferEnvelopeKind? kind, {bool changed = true}) {
    if (kind == _kind) return;
    _kind = kind;
    if (kind != null) {
      final handle = _handle;
      MpxDiagnostics.current.emit(
        MpxEventLevel.info,
        EnvelopeOp.started,
        fields: () => {'kind': kind.name, 'handle': ?handle},
      );
    }
    if (kind == TransferEnvelopeKind.continuedProcessing) {
      _startPushing();
    } else {
      _stopPushing();
    }
    if (changed) _changed();
  }

  /// Back in the foreground: whatever holds the process lets go, and the
  /// envelope stays armed for the next background.
  void _withdraw() {
    final held = _kind;
    final asked = _submission == _Submission.asked;
    final waiting = _submitTimer != null;
    _cancelTimers();
    _submission = _Submission.idle;
    _kind = null;
    if (_handle == null) return;
    if (held != null || asked) unawaited(_invoke('withdraw'));
    if (held != null) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.info,
        EnvelopeOp.withdrawn,
        fields: () => {'kind': held.name, 'why': 'foreground'},
      );
    }
    if (held != null || waiting) _changed();
  }

  void _disarm() {
    _cancelTimers();
    _handle = null;
    _kind = null;
    _submission = _Submission.idle;
  }

  void _cancelTimers() {
    _submitTimer?.cancel();
    _submitTimer = null;
    _submitDueAt = null;
    _stopPushing();
  }

  void _changed() {
    if (_handle == null) return;
    _events.add(
      TransferEnvelopeEvent.changed(kind: _kind, submitDueAt: _submitDueAt),
    );
  }

  // --- Progress ---------------------------------------------------------------

  void _startPushing() {
    _stopPushing();
    _pushedFraction = 0;
    _push();
    _pushTimer = Timer.periodic(progressInterval, (_) => _push());
  }

  void _stopPushing() {
    _pushTimer?.cancel();
    _pushTimer = null;
    _pushed = null;
  }

  /// Pushes the engine's progress when it changed since the last push. The
  /// fraction shown never goes back within one task, though a job joining
  /// the envelope adds to the total: a Live Activity that moves backwards
  /// reads as stuck.
  void _push() {
    final progress = _progress;
    final config = _config;
    final handle = _handle;
    if (progress == null || config == null || handle == null) return;
    if (progress == _pushed) return;
    _pushed = progress;
    double? fraction;
    if (progress.total case final total? when total > 0) {
      fraction = _pushedFraction = math.max(
        _pushedFraction,
        (progress.done / total).clamp(0.0, 1.0),
      );
    }
    unawaited(
      _invoke('progress', {
        'handle': handle,
        'fraction': fraction,
        'subtitle': _subtitleOf(config, progress),
      }),
    );
    final jobs = progress.jobs.length;
    MpxDiagnostics.current.emit(
      MpxEventLevel.trace,
      EnvelopeOp.progressPushed,
      fields: () => {'fraction': ?fraction, 'jobs': jobs},
    );
  }

  static String _subtitleOf(
    TransferEnvelopeConfig config,
    TransferEnvelopeProgress progress,
  ) => config.progressText?.call(progress) ?? config.text ?? '';

  // --- Attaching and the native log ------------------------------------------

  /// Attaches to the native part once: it answers what it still holds (an
  /// envelope armed before a restart of the Dart side), whether
  /// continued-processing tasks exist here, and the records it kept while
  /// no Dart side was attached, which are emitted now.
  Future<_Attached> _attach() => _attaching ??= () async {
    final Map<String, Object?>? reply;
    try {
      reply = await _channel.invokeMapMethod<String, Object?>('attach', {
        'logBytes': nativeLogBytes,
      });
    } on MissingPluginException {
      // No native part (a host or test without the plugin): nothing holds
      // the process, and nothing is submitted.
      return _attached = _Attached.none();
    } on Object {
      _attaching = null;
      rethrow;
    }
    final live = reply?['live'];
    final attached = _Attached(
      live: {
        if (live is List)
          for (final handle in live)
            if (handle is String) handle,
      },
      kind: _kindOf(reply?['kind']),
      foreground: reply?['foreground'] != false,
      continued: reply?['continued'] == true,
    );
    _merge(reply?['records']);
    return _attached = attached;
  }();

  void _merge(Object? records) {
    if (records is! List || records.isEmpty) return;
    final now = _now();
    DateTime? oldest;
    var merged = 0;
    for (final record in records) {
      if (record is! Map) continue;
      final op = _ops[record['op']];
      final level = _levels[record['level']];
      final ms = record['time'];
      if (op == null || level == null || ms is! int) continue;
      final time = DateTime.fromMillisecondsSinceEpoch(ms);
      if (oldest == null || time.isBefore(oldest)) oldest = time;
      merged++;
      final fields = record['fields'];
      MpxDiagnostics.current.report(
        MpxEvent(
          time: time,
          level: level,
          op: op,
          fields: {
            if (fields is Map)
              for (final MapEntry(:key, :value) in fields.entries)
                if (key is String)
                  if (value case final num number)
                    key: number
                  else if (value case final bool flag)
                    key: flag
                  else if (value case final String text)
                    key: MpxEvent.clip(text),
            'native': true,
          },
        ),
      );
    }
    if (merged == 0) return;
    final ageS = now.difference(oldest!).inSeconds;
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      EnvelopeOp.nativeMerged,
      fields: () => {'records': merged, 'oldestAgeS': ageS},
    );
  }

  /// Calls the native part after it is attached, in the order called.
  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      await _attach();
      await _channel.invokeMethod<void>(method, args);
    } on Object catch (_, stackTrace) {
      // A lost call leaves the native part holding what it held; its own
      // handlers still end it. The error stays out of the event.
      MpxDiagnostics.current.emit(
        MpxEventLevel.warning,
        EnvelopeOp.refused,
        fields: () => {'code': 'error', 'call': method},
        stackTrace: stackTrace,
      );
    }
  }

  static final Map<Object?, EnvelopeOp> _ops = EnvelopeOp.values.asNameMap();
  static final Map<Object?, MpxEventLevel> _levels = MpxEventLevel.values
      .asNameMap();

  static TransferEnvelopeKind? _kindOf(Object? name) =>
      TransferEnvelopeKind.values.asNameMap()[name];

  static TransferEnvelopeEndCause _causeOf(Object? name) =>
      TransferEnvelopeEndCause.values.asNameMap()[name] ??
      TransferEnvelopeEndCause.stop;
}

/// What the native part answered when this side attached.
final class _Attached {
  _Attached({
    required this.live,
    required this.kind,
    required this.foreground,
    required this.continued,
  });

  /// No native part answered.
  _Attached.none()
    : live = const {},
      kind = null,
      foreground = true,
      continued = false;

  /// The envelope it still holds armed, from before a restart of the Dart
  /// side (at most one); empty when none.
  final Set<String> live;

  /// What held the process then.
  final TransferEnvelopeKind? kind;

  /// Whether the app is in the foreground; kept current by the lifecycle
  /// calls.
  bool foreground;

  /// Whether continued-processing tasks exist here (iOS 26 and later).
  final bool continued;
}

/// The continued-processing task since the app last left the foreground.
enum _Submission {
  /// None asked for yet.
  idle,

  /// Asked for: in flight, accepted, or running.
  asked,

  /// The system refused it: the background task alone holds the process
  /// until the app is in the foreground again.
  refused,
}
