import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:timeago/timeago.dart' as timeago;

/// Relative "time ago" labels for [DateTime].
extension TimeAgoExtension on DateTime {
  /// Formats this instant relative to now: `12 seconds ago`, `3 days ago`.
  ///
  /// Instants older than [absoluteAfter] render as a calendar date instead
  /// (`Jan 15`, or `Jan 15, 2024` outside the current year); pass `null` to
  /// stay relative. A future instant (a server clock ahead of the device's)
  /// is clamped to now.
  ///
  /// [now] stands for the current time, for a test.
  String timeAgo({
    Duration? absoluteAfter = const Duration(days: 30),
    DateTime? now,
  }) => _format(
    style: _TimeAgoStyle.long,
    absoluteAfter: absoluteAfter,
    now: now,
  );

  /// Compact relative label for a post's header: `12s`, `5m`, `3h`, `2d`,
  /// then a calendar date. No "ago".
  ///
  /// [now] stands for the current time, for a test.
  String timeAgoShort({
    Duration? absoluteAfter = const Duration(days: 7),
    DateTime? now,
  }) => _format(
    style: _TimeAgoStyle.short,
    absoluteAfter: absoluteAfter,
    now: now,
  );

  String _format({
    required _TimeAgoStyle style,
    required Duration? absoluteAfter,
    required DateTime? now,
  }) {
    final current = (now ?? DateTime.now()).toLocal();
    // Clamp future instants (server/device clock skew) so timeago does not
    // count negative seconds.
    final instant = (isAfter(current) ? current : this).toLocal();
    if (absoluteAfter case final threshold?
        when current.difference(instant) >= threshold) {
      final format = current.year == instant.year
          ? DateFormat.MMMd(_locale)
          : DateFormat.yMMMd(_locale);
      return format.format(instant);
    }
    return timeago.format(instant, locale: style.register(), clock: current);
  }
}

const String _locale = 'en';

// --- timeago messages ---

final Set<String> _registeredLocales = {};

enum _TimeAgoStyle {
  long,
  short;

  /// timeago looks messages up in a process-wide registry keyed by locale and
  /// silently falls back to stock English for unknown keys. Registering on
  /// first use keeps callers free of a bootstrap step that could run after the
  /// first formatted frame. Returns the registry key.
  String register() {
    final key = switch (this) {
      long => _locale,
      short => '${_locale}_compact',
    };
    if (_registeredLocales.add(key)) {
      timeago.setLocaleMessages(key, switch (this) {
        long => _LongMessages(),
        short => _CompactMessages(),
      });
    }
    return key;
  }
}

/// Counts sub-minute time in seconds where stock timeago says "a moment".
mixin _SecondsCount on timeago.LookupMessages {
  String secondsUnit(int seconds);

  @override
  String lessThanOneMinute(int seconds) {
    // Sub-second elapsed time reads "1 …": the unit agrees with the shown
    // count, not the raw 0.
    final shown = math.max(seconds, 1);
    return '$shown ${secondsUnit(shown)}';
  }
}

final class _LongMessages extends timeago.EnMessages with _SecondsCount {
  @override
  String secondsUnit(int seconds) => Intl.pluralLogic(
    seconds,
    locale: _locale,
    one: 'second',
    other: 'seconds',
  );
}

/// `12s`, `5m`, `3h`, `2d`: the labels a feed's header carries.
final class _CompactMessages extends timeago.EnShortMessages
    with _SecondsCount {
  @override
  String secondsUnit(int seconds) => 's';
  @override
  String lessThanOneMinute(int seconds) => seconds < 45 ? 'now' : '1m';
  @override
  String aboutAMinute(int minutes) => '1m';
  @override
  String minutes(int minutes) => '${minutes}m';
  @override
  String aboutAnHour(int minutes) => '1h';
  @override
  String hours(int hours) => '${hours}h';
  @override
  String aDay(int hours) => '1d';
  @override
  String days(int days) => '${days}d';
  @override
  String aboutAMonth(int days) => '1mo';
  @override
  String months(int months) => '${months}mo';
  @override
  String aboutAYear(int year) => '1y';
  @override
  String years(int years) => '${years}y';
  @override
  String wordSeparator() => '';
}
