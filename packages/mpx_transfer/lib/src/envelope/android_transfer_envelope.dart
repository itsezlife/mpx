import 'dart:async';

import 'package:flutter/services.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/envelope_op.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope_config.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';

/// The OS envelope on Android: a user-initiated data transfer job on
/// Android 14 and later, a `dataSync` foreground service before, with one
/// notification for every job inside it showing the engine's progress and
/// "cancel all".
///
/// Its rule is [TransferEnvelopeStartRule.long]: neither kind may start
/// from the background, so the engine asks for it when a long job is
/// created, while the app is visible. Without the host's permissions
/// (README, "Android") the platform refuses it; the refusal is caught on
/// the native side and the jobs run in process.
///
/// The native part writes each of its records to logcat (tag
/// `mpx_transfer`) and, while no Dart side is attached, to a ring file of
/// at most [nativeLogBytes]. At [live], the first call the engine makes,
/// those records are reported through `MpxDiagnostics.current` with their
/// original time and `fields.native` true, then `envelope` `nativeMerged`.
///
/// One per process, passed to `Transfers.open(envelope:)` on Android only.
final class AndroidTransferEnvelope implements TransferEnvelope {
  /// The envelope over [channel] (the plugin's unless given), whose native
  /// ring keeps at most [nativeLogBytes].
  AndroidTransferEnvelope({
    MethodChannel channel = defaultChannel,
    this.nativeLogBytes = defaultNativeLogBytes,
    DateTime Function() now = DateTime.now,
  }) : _channel = channel,
       _now = now {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  /// The plugin's channel.
  static const MethodChannel defaultChannel = MethodChannel(
    'dev.mpx.transfer/envelope',
  );

  /// The native ring's size on disk by default: 2 MiB.
  static const int defaultNativeLogBytes = 2 * 1024 * 1024;

  /// The most bytes the native ring keeps while Dart is not running.
  final int nativeLogBytes;

  final MethodChannel _channel;
  final DateTime Function() _now;

  late final StreamController<TransferEnvelopeEvent> _events =
      StreamController.broadcast(sync: true, onListen: _flushUnheard);

  // Events the native side sent before the engine listened (a tap that
  // launched the app arrives at attach).
  final List<TransferEnvelopeEvent> _unheard = [];

  // Every call goes through this chain, so the native side sees them in the
  // order the engine made them: an update or a stop the engine sends
  // before a start answered still lands after that start.
  Future<void> _tail = Future.value();
  Future<Set<String>>? _attached;
  TransferEnvelopeConfig? _config;

  @override
  TransferEnvelopeStartRule get startRule => TransferEnvelopeStartRule.long;

  @override
  Future<Set<String>> live() => _attached ??= _attach();

  @override
  Future<TransferEnvelopeStart> start(
    TransferEnvelopeProgress progress,
    TransferEnvelopeConfig config,
  ) async {
    _config = config;
    unawaited(live());
    final Object? answer;
    try {
      answer = await _send<Object?>('start', _content(progress, config));
    } on MissingPluginException {
      return const TransferEnvelopeStart.refused('platform');
    } on PlatformException catch (error) {
      return TransferEnvelopeStart.refused(MpxEvent.clip(error.code));
    }
    return switch (answer) {
      {'handle': final String handle, 'kind': final String kind} =>
        TransferEnvelopeStart.started(
          handle,
          kind: TransferEnvelopeKind.values.asNameMap()[kind],
        ),
      {'refused': final String code} => TransferEnvelopeStart.refused(
        MpxEvent.clip(code),
      ),
      _ => const TransferEnvelopeStart.refused('malformed'),
    };
  }

  @override
  void adopt(
    String handle,
    TransferEnvelopeProgress progress,
    TransferEnvelopeConfig config,
  ) {
    _config = config;
    _fire('adopt', {..._content(progress, config), 'handle': handle});
  }

  @override
  void update(TransferEnvelopeProgress progress) {
    final config = _config;
    if (config == null) return;
    _fire('update', _content(progress, config));
  }

  @override
  void stop() => _fire('stop', const {});

  @override
  Stream<TransferEnvelopeEvent> get events => _events.stream;

  /// Stops taking the native side's calls and closes [events].
  Future<void> close() {
    _channel.setMethodCallHandler(null);
    return _events.close();
  }

  // --- Calls -----------------------------------------------------------------

  Future<T?> _send<T>(String method, Map<String, Object?> arguments) {
    final call = _tail.then((_) => _channel.invokeMethod<T>(method, arguments));
    _tail = call.then<void>((_) {}, onError: (Object _) {});
    return call;
  }

  // A call nobody awaits: its failure is reported, never thrown into the
  // engine's zone.
  void _fire(String method, Map<String, Object?> arguments) {
    unawaited(
      _send<void>(method, arguments).catchError((Object error, StackTrace st) {
        MpxDiagnostics.current.emit(
          MpxEventLevel.warning,
          EnvelopeOp.refused,
          fields: () => {
            'code': error is PlatformException
                ? MpxEvent.clip(error.code)
                : 'channel',
            'call': method,
          },
          stackTrace: st,
        );
      }),
    );
  }

  Map<String, Object?> _content(
    TransferEnvelopeProgress progress,
    TransferEnvelopeConfig config,
  ) => {
    'jobs': [for (final id in progress.jobs) id as String],
    'shownJob': progress.jobs.firstOrNull as String?,
    'done': progress.done,
    'total': progress.total,
    'title': config.title,
    'text': config.text,
    'cancelAllLabel': config.cancelAllLabel,
    'progressText': config.progressText?.call(progress),
    'icon': config.icon,
  };

  // --- Attach and the native ring --------------------------------------------

  Future<Set<String>> _attach() async {
    final Map<Object?, Object?>? answer;
    try {
      answer = await _send<Map<Object?, Object?>>('attach', {
        'logBytes': nativeLogBytes,
      });
    } on MissingPluginException {
      return const {};
    }
    final records = [
      for (final record in answer?['records'] as List<Object?>? ?? const [])
        if (record is Map<Object?, Object?>) record,
    ];
    _merge(records);
    return {
      for (final handle in answer?['live'] as List<Object?>? ?? const [])
        if (handle is String) handle,
    };
  }

  void _merge(List<Map<Object?, Object?>> records) {
    if (records.isEmpty) return;
    DateTime? oldest;
    for (final record in records) {
      final event = _eventOf(record, native: true);
      if (event == null) continue;
      MpxDiagnostics.current.report(event);
      if (oldest == null || event.time.isBefore(oldest)) oldest = event.time;
    }
    final age = oldest == null ? 0 : _now().difference(oldest).inSeconds;
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      EnvelopeOp.nativeMerged,
      fields: () => {'records': records.length, 'oldestAgeS': age},
    );
  }

  MpxEvent? _eventOf(Map<Object?, Object?> record, {required bool native}) {
    final op = EnvelopeOp.values.asNameMap()[record['op']];
    final level = MpxEventLevel.values.asNameMap()[record['level']];
    final time = record['time'];
    if (op == null || level == null || time is! int) return null;
    return MpxEvent(
      time: DateTime.fromMillisecondsSinceEpoch(time),
      level: level,
      op: op,
      jobId: record['jobId'] as String?,
      fields: {
        for (final MapEntry(:key, :value)
            in (record['fields'] as Map<Object?, Object?>? ?? const {}).entries)
          if (key is String)
            if (value case final num number)
              key: number
            else if (value case final bool flag)
              key: flag
            else if (value case final String text)
              key: MpxEvent.clip(text),
        if (native) 'native': true,
      },
    );
  }

  // --- Native calls ----------------------------------------------------------

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'record':
        if (call.arguments case final Map<Object?, Object?> record) {
          if (_eventOf(record, native: false) case final event?) {
            MpxDiagnostics.current.report(event);
          }
        }
      case 'event':
        if (call.arguments case final Map<Object?, Object?> event) {
          if (_seamEventOf(event) case final seam?) _deliver(seam);
        }
    }
    return null;
  }

  TransferEnvelopeEvent? _seamEventOf(Map<Object?, Object?> event) =>
      switch (event['type']) {
        'systemEnded' => TransferEnvelopeEvent.systemEnded(
          cause:
              TransferEnvelopeEndCause.values.asNameMap()[event['cause']] ??
              TransferEnvelopeEndCause.stop,
        ),
        'userCancelledAll' => const TransferEnvelopeEvent.userCancelledAll(),
        'notificationTap' => switch (event['job']) {
          final String job => TransferEnvelopeEvent.notificationTap(
            TransferId.parse(job),
          ),
          _ => null,
        },
        _ => null,
      };

  void _deliver(TransferEnvelopeEvent event) {
    if (_events.hasListener) {
      _events.add(event);
    } else {
      _unheard.add(event);
    }
  }

  void _flushUnheard() {
    final unheard = [..._unheard];
    _unheard.clear();
    unheard.forEach(_events.add);
  }
}
