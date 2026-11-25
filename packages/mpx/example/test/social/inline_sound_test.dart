import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/inline_sound.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

const _a = MediaKey.remote('a');
const _b = MediaKey.remote('b');

void main() {
  late FakePlayerBackend backend;
  late PlayerPool pool;
  late PlaybackClock clock;
  late InlineSound sound;

  setUp(() {
    backend = FakePlayerBackend();
    pool = PlayerPool(backend: backend, budget: const PlayerBudget());
    clock = PlaybackClock(ticks: ManualPlaybackTickSource());
    sound = InlineSound(pool, clock: clock);
  });

  tearDown(() {
    sound.dispose();
    pool.dispose();
    clock.dispose();
  });

  PlayerState stateOf(MediaKey key) => sound.lease!.state.value;

  test('the switch gives the sound to a clip, from where its loop is', () {
    sound
      ..report(_a, 1, clipPosition: () => const Duration(seconds: 12))
      ..toggle(_a);

    expect(sound.playing, _a);
    expect(sound.isSoundOn, isTrue);
    expect(stateOf(_a).volume, 1);
    expect(sound.lease!.position, const Duration(seconds: 12));
  });

  test('the place of the clip that plays is its player\'s, of no other', () {
    sound
      ..report(_a, 1, clipPosition: () => const Duration(seconds: 3))
      ..report(_b, 0.2)
      ..toggle(_a);

    expect(sound.positionOf(_a), const Duration(seconds: 3));
    expect(sound.positionOf(_b), isNull);

    sound.suspend();

    expect(sound.positionOf(_a), isNull);
  });

  test('switching it off on the same clip keeps the player, muted: one '
      'track, not two', () {
    sound
      ..report(_a, 1)
      ..toggle(_a);
    final lease = sound.lease;

    sound.toggle(_a);

    expect(sound.lease, same(lease));
    expect(sound.playing, _a);
    expect(sound.isSoundOn, isFalse);
    expect(stateOf(_a).volume, 0);
    expect(sound.isWanted, isFalse);
  });

  test('switching it on again is the volume only', () {
    sound
      ..report(_a, 1)
      ..toggle(_a)
      ..toggle(_a);
    final lease = sound.lease;

    sound.toggle(_a);

    expect(sound.lease, same(lease));
    expect(stateOf(_a).volume, 1);
    expect(sound.isWanted, isTrue);
  });

  test('a muted clip that leaves the view gives its player back', () {
    sound
      ..report(_a, 1)
      ..toggle(_a)
      ..toggle(_a)
      ..report(_a, 0.2);

    expect(sound.lease, isNull);
    expect(sound.playing, isNull);
  });

  test('the sound goes on to the next clip in view while it is wanted', () {
    sound
      ..report(_a, 1)
      ..report(_b, 0.1)
      ..toggle(_a)
      ..report(_a, 0)
      ..report(_b, 0.9);

    expect(sound.playing, _b);
    expect(sound.isSoundOn, isTrue);
  });

  test('a pause layer pauses the player and its end plays it again', () {
    sound
      ..report(_a, 1)
      ..toggle(_a);
    expect(stateOf(_a).playing, isTrue);

    clock.setPaused(PlaybackPauseLayer.appInactive, paused: true);
    expect(stateOf(_a).playing, isFalse);

    clock.setPaused(PlaybackPauseLayer.appInactive, paused: false);
    expect(stateOf(_a).playing, isTrue);
  });

  test(
    'coming back to view takes the sound again, from where the loop is',
    () async {
      sound
        ..report(_a, 1, clipPosition: () => const Duration(seconds: 3))
        ..toggle(_a)
        ..report(_a, 0);
      expect(sound.lease, isNull);

      sound.report(_a, 1, clipPosition: () => const Duration(seconds: 7));
      await pumpEventQueue();

      expect(sound.playing, _a);
      expect(sound.lease!.position, const Duration(seconds: 7));
      expect(stateOf(_a).playing, isTrue);
    },
  );

  test('a surface over the list takes the sound and gives it back', () {
    sound
      ..report(_a, 1)
      ..toggle(_a)
      ..suspend();
    expect(sound.lease, isNull);

    sound.resume();

    expect(sound.playing, _a);
    expect(stateOf(_a).playing, isTrue);
  });

  group('the system volume went up', () {
    test('gives the sound to the clip most in view when none has it', () {
      sound
        ..report(_a, 0.7)
        ..report(_b, 0.9)
        ..unmute();

      expect(sound.playing, _b);
      expect(sound.isSoundOn, isTrue);
      expect(sound.isWanted, isTrue);
    });

    test('unmutes the clip that plays muted', () {
      sound
        ..report(_a, 1)
        ..toggle(_a)
        ..toggle(_a);
      expect(stateOf(_a).volume, 0);

      sound.unmute();

      expect(stateOf(_a).volume, 1);
      expect(sound.isWanted, isTrue);
    });

    test('changes nothing when the sound is already on', () {
      sound
        ..report(_a, 1)
        ..toggle(_a);
      final lease = sound.lease;

      sound.unmute();

      expect(sound.lease, same(lease));
      expect(stateOf(_a).volume, 1);
    });

    test('does nothing with no clip in view', () {
      sound.unmute();

      expect(sound.playing, isNull);
    });
  });
}
