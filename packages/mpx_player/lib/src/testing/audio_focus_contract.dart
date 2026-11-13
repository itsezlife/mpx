import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_player/src/audio/audio_focus.dart';

/// The contract every [AudioFocus] meets; see its documentation.
///
/// It holds what the player pool relies on: requests and abandons come in
/// any order and any number without failing, and [AudioFocus.changes] can be
/// listened to more than once and says nothing by itself while nothing
/// happens on the device. What the platform reports is the backend's own
/// test.
abstract final class AudioFocusContract {
  /// Runs it as a test group. [create] builds a fresh focus for each test;
  /// [dispose] releases it, when it needs releasing.
  static void run(
    AudioFocus Function() create, {
    void Function(AudioFocus focus)? dispose,
  }) {
    group('AudioFocus contract', () {
      late AudioFocus focus;

      setUp(() => focus = create());
      tearDown(() => dispose?.call(focus));

      test('a request is given back, in pairs and repeated', () {
        focus
          ..request()
          ..abandon()
          ..request()
          ..request()
          ..abandon()
          ..abandon();
      });

      test('giving back what was never asked for is allowed', () {
        focus.abandon();
      });

      test('the changes can be listened to twice and let go', () async {
        final first = focus.changes.listen((_) {});
        final second = focus.changes.listen((_) {});
        await first.cancel();
        await second.cancel();
      });

      test('nothing is said while the device is quiet', () async {
        final heard = <AudioFocusChange>[];
        final listening = focus.changes.listen(heard.add);
        focus
          ..request()
          ..abandon();
        await Future<void>.delayed(Duration.zero);
        await listening.cancel();
        expect(heard, isEmpty);
      });
    });
  }
}
