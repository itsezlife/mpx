import 'package:flutter/foundation.dart';

/// Wall-clock timings of one successful initialization run.
///
/// Captured once by the initialization pipeline; immutable for the rest of
/// the process lifetime.
@immutable
final class InitializationMetrics {
  /// Creates metrics from [steps] in execution order.
  const InitializationMetrics({required this.steps, required this.completedAt});

  /// Step timings in execution order.
  final List<InitializationStepMetric> steps;

  /// When the last step finished (local time).
  final DateTime completedAt;

  /// Sum of every step's [InitializationStepMetric.elapsed].
  Duration get total =>
      steps.fold(Duration.zero, (sum, step) => sum + step.elapsed);
}

/// Timing of a single named initialization step.
@immutable
final class InitializationStepMetric {
  /// Creates a step timing.
  const InitializationStepMetric({required this.name, required this.elapsed});

  /// Step name as declared in the pipeline (diagnostic, not localized).
  final String name;

  /// Time the step took, microsecond precision.
  final Duration elapsed;
}
