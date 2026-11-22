import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mpx_example/social/src/common/util/count_format.dart';
import 'package:mpx_example/social/src/common/util/time_ago_extension.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  final now = DateTime.utc(2026, 11, 22, 12);

  group('timeAgoShort', () {
    String at(Duration ago) => now.subtract(ago).timeAgoShort(now: now);

    test('reads as the shortest label that tells how long ago', () {
      expect(at(const Duration(seconds: 10)), 'now');
      expect(at(const Duration(minutes: 5)), '5m');
      expect(at(const Duration(hours: 3)), '3h');
      expect(at(const Duration(days: 2)), '2d');
    });

    test('older than a week is a calendar date', () {
      expect(at(const Duration(days: 8)), 'Nov 14');
      expect(
        DateTime.utc(2025, 3, 2, 12).timeAgoShort(now: now),
        'Mar 2, 2025',
      );
    });

    test('a time ahead of the clock is now', () {
      expect(now.add(const Duration(minutes: 5)).timeAgoShort(now: now), 'now');
    });
  });

  group('timeAgo', () {
    test('says how long ago, with the unit', () {
      expect(
        now.subtract(const Duration(seconds: 1)).timeAgo(now: now),
        '1 second ago',
      );
      expect(
        now.subtract(const Duration(minutes: 5)).timeAgo(now: now),
        '5 minutes ago',
      );
      expect(
        now.subtract(const Duration(days: 3)).timeAgo(now: now),
        '3 days ago',
      );
    });

    test('stays relative when asked not to turn into a date', () {
      expect(
        now
            .subtract(const Duration(days: 90))
            .timeAgo(now: now, absoluteAfter: null),
        isNot(contains('Aug')),
      );
    });
  });

  test('counts read in intl\'s compact form, nothing for zero', () {
    expect(0.compact, '');
    expect(999.compact, '999');
    expect(1200.compact, '1.2K');
    expect(34000.compact, '34K');
    expect(1500000.compact, '1.5M');
  });

  test('a duration reads as a clock', () {
    expect(const Duration(seconds: 7).clock, '0:07');
    expect(const Duration(seconds: 65).clock, '1:05');
    expect(const Duration(hours: 1, minutes: 2, seconds: 3).clock, '1:02:03');
  });
}
