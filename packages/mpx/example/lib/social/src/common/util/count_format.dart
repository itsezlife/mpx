import 'package:intl/intl.dart';

/// How a count reads on a card.
extension CompactCount on int {
  /// Nothing for zero (a heart with no number), else `999`, `1.2K`, `34K`,
  /// `1.5M`: intl's compact form.
  String get compact => this <= 0 ? '' : NumberFormat.compact().format(this);
}

/// How a length of time reads on a video.
extension ClockDuration on Duration {
  /// `0:07`, `1:05`, `1:02:03`.
  String get clock {
    final total = inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = (total % 60).toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
        : '$minutes:$seconds';
  }
}
