import 'dart:async';

import 'package:flutter/services.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_core/mpx_core.dart';

/// The one method channel and event stream the native side of the package
/// talks through, shared by compression and recording.
///
/// Every native job carries an id from [nextJobId]. Its events arrive on one
/// stream as maps with a `job` id and a `type`:
///
/// | type | fields |
/// | --- | --- |
/// | `progress` | `bytes`, `positionUs`, `fraction` |
/// | `done` | `path`, `size`, `durationUs`, `width`, `height`, `headerRewritten`, `reencoded` |
/// | `error` | `code` (`failed`, `permission`), `message` |
///
/// The stream is listened to only while a job is registered.
final class CaptureChannel {
  CaptureChannel._();

  /// The process's channel.
  static final CaptureChannel instance = CaptureChannel._();

  /// The method channel; its name is the native side's too.
  static const MethodChannel methods = MethodChannel('dev.mpx.capture/methods');

  static const EventChannel _events = EventChannel('dev.mpx.capture/events');

  final Map<int, CaptureJob> _jobs = {};
  // Cancelled in [register] once the last registered job settles.
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _subscription;
  var _lastJobId = 0;

  /// A fresh job id.
  int nextJobId() => ++_lastJobId;

  /// Routes events for [id] to [job] until it settles.
  void register(int id, CaptureJob job) {
    _jobs[id] = job;
    _subscription ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error, StackTrace stackTrace) {
        // A broken event stream leaves no job able to finish: fail them all.
        for (final job in _jobs.values.toList()) {
          job.fail(CaptureFailed('event stream: $error'), stackTrace);
        }
        _jobs.clear();
      },
    );
    unawaited(
      job.output.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        _jobs.remove(id);
        if (_jobs.isEmpty) {
          final subscription = _subscription;
          _subscription = null;
          unawaited(subscription?.cancel());
        }
      }),
    );
  }

  /// Calls [method] with [arguments], turning a platform error into a
  /// [CaptureException].
  Future<T?> invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw exceptionOf(error.code, error.message ?? error.code);
    } on MissingPluginException catch (error) {
      throw CaptureFailed('no native side: ${error.message}');
    }
  }

  /// The exception for a native error [code].
  static CaptureException exceptionOf(String code, String message) =>
      switch (code) {
        'permission' => CapturePermissionDenied(message),
        _ => CaptureFailed(message),
      };

  /// Reads a `done` event or method result into an output.
  static CaptureOutput outputOf(Map<Object?, Object?> map) => CaptureOutput(
    path: map['path']! as String,
    size: map['size']! as int,
    duration: Duration(microseconds: map['durationUs']! as int),
    dimensions: MediaDimensions(map['width']! as int, map['height']! as int),
    headerRewritten: map['headerRewritten']! as bool,
    reencoded: map['reencoded'] as bool? ?? true,
  );

  void _onEvent(Object? event) {
    if (event is! Map<Object?, Object?>) return;
    final job = _jobs[event['job']];
    if (job == null) return;
    switch (event['type']) {
      case 'progress':
        job.report(
          CaptureProgress(
            bytesWritten: event['bytes']! as int,
            position: Duration(microseconds: event['positionUs']! as int),
            fraction: (event['fraction']! as num).toDouble().clamp(0, 1),
          ),
        );
      case 'done':
        job.complete(
          outputOf(event),
          fraction: (event['fraction'] as num?)?.toDouble() ?? 1,
        );
      case 'error':
        job.fail(
          exceptionOf(
            event['code'] as String? ?? 'failed',
            event['message'] as String? ?? 'native error',
          ),
        );
    }
  }
}
