import 'dart:math' as math;

import 'package:meta/meta.dart';

/// {@template http_bytes_retry_backoff}
/// Jittered exponential backoff for [HttpBytesRetryMiddleware] and for
/// [HttpBytesClient.upload].
///
/// Delay for attempt `n` (0-based, before the next try) is drawn from
/// `[minDelay, window]`, where `window = min(maxDelay, initialDelay ×
/// factorⁿ)`. With the default [minDelay] of zero that is full jitter,
/// `random(0, window)`. [maxElapsed] is the budget across sleeps;
/// [maxRetries] caps attempt count.
/// {@endtemplate}
@immutable
final class HttpBytesRetryBackoff {
  /// {@macro http_bytes_retry_backoff}
  const HttpBytesRetryBackoff({
    this.maxRetries = 3,
    this.initialDelay = const Duration(milliseconds: 200),
    this.maxDelay = const Duration(seconds: 10),
    this.maxElapsed = const Duration(seconds: 30),
    this.factor = 2.0,
    this.minDelay = Duration.zero,
  }) : assert(maxRetries >= 0, 'maxRetries must be >= 0'),
       assert(factor >= 1.0, 'factor must be >= 1.0');

  /// Retries of one part of an upload: five tries in all (the first and
  /// [maxRetries] 4), waits growing from 1 s, each capped at 30 s.
  ///
  /// 30 s caps one wait, not the series: [maxElapsed] is four full waits, so
  /// it never stops the series before the fifth try. The floor of 1 s keeps
  /// a retry from going straight back to a server that just refused it; the
  /// jitter above it keeps parallel parts from retrying in step.
  static const uploadPart = HttpBytesRetryBackoff(
    maxRetries: 4,
    initialDelay: Duration(seconds: 1),
    minDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 30),
    maxElapsed: Duration(minutes: 2),
  );

  /// Maximum number of **retries** after the first attempt (not total tries).
  final int maxRetries;

  /// Base delay before the first retry (attempt 0).
  final Duration initialDelay;

  /// Cap on any single backoff delay.
  final Duration maxDelay;

  /// Budget for all sleeps; if the next delay would exceed it, retry stops
  /// and the last error is rethrown.
  final Duration maxElapsed;

  /// Exponential growth multiplier (`initialDelay × factorⁿ`).
  final double factor;

  /// Floor of every delay (at most the attempt's window). Zero is full
  /// jitter.
  final Duration minDelay;

  /// Jittered delay for [attempt] (0 = first retry).
  Duration backoff(int attempt, math.Random random) {
    final baseMicros = initialDelay.inMicroseconds * math.pow(factor, attempt);
    final capMicros = maxDelay.inMicroseconds.toDouble();
    final window = math.min(capMicros, baseMicros.toDouble());
    final floor = math.min(minDelay.inMicroseconds.toDouble(), window);
    final jittered = floor + random.nextDouble() * (window - floor);
    return Duration(microseconds: jittered.round());
  }

  /// Whether sleeping [delay] after [elapsed] still fits [maxElapsed].
  bool withinBudget(Duration elapsed, Duration delay) =>
      elapsed + delay <= maxElapsed;
}
