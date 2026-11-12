import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

void main() {
  const a = MediaKey.remote('a');
  const b = MediaKey.remote('b');

  late FakePlayerBackend backend;
  late PlayerPool pool;
  late List<MediaKey> leftScreen;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  PlayerPool makePool({bool hostDecides = false}) => PlayerPool(
    backend: backend,
    onSoundOwnerLeftScreen: hostDecides ? leftScreen.add : null,
  );

  setUp(() {
    backend = FakePlayerBackend();
    leftScreen = [];
    pool = makePool();
  });
  tearDown(() => pool.dispose());

  group('one audible player', () {
    test('a player that plays with sound owns it and takes focus', () async {
      pool.lease(a).play();
      await settle();

      expect(pool.soundOwner, a);
      expect(backend.audioFocus.held, isTrue);
    });

    test('a muted player does not take the sound', () async {
      pool.lease(a)
        ..setVolume(0)
        ..play();
      await settle();

      expect(pool.soundOwner, isNull);
      expect(backend.audioFocus.held, isFalse);
    });

    test('a new audible player silences the previous', () async {
      pool.budget = const PlayerBudget(active: 2, prepared: 0);
      final first = pool.lease(a)..play();
      await settle();
      pool.lease(b).play();
      await settle();

      expect(pool.soundOwner, b);
      expect(first.state.value.playing, isFalse);
      expect(backend.audioFocus.requests, 1);
    });

    test('a muted player plays beside the sound owner', () async {
      pool.budget = const PlayerBudget(active: 2, prepared: 0);
      final owner = pool.lease(a)..play();
      final muted = pool.lease(b)
        ..setVolume(0)
        ..play();
      await settle();

      expect(owner.state.value.playing, isTrue);
      expect(muted.state.value.playing, isTrue);
      expect(pool.soundOwner, a);
    });

    test('unmuting a playing player makes it the owner', () async {
      pool.budget = const PlayerBudget(active: 2, prepared: 0);
      final first = pool.lease(a)..play();
      final second = pool.lease(b)
        ..setVolume(0)
        ..play();
      await settle();

      second.setVolume(1);

      expect(pool.soundOwner, b);
      expect(first.state.value.playing, isFalse);
    });

    test('pausing, muting or releasing the owner gives focus back', () async {
      final lease = pool.lease(a)..play();
      await settle();
      lease.pause();
      expect(pool.soundOwner, isNull);
      expect(backend.audioFocus.held, isFalse);

      lease.play();
      await settle();
      lease.setVolume(0);
      expect(pool.soundOwner, isNull);

      lease
        ..setVolume(1)
        ..play();
      await settle();
      lease.release();
      expect(pool.soundOwner, isNull);
      expect(backend.audioFocus.held, isFalse);
    });

    test('the owner reaching its end gives focus back', () async {
      final lease = pool.lease(a)..play();
      await settle();
      backend.latestFor(a)!.advance(const Duration(minutes: 2));

      expect(lease.state.value.phase, PlayerPhase.ended);
      expect(pool.soundOwner, isNull);
      expect(backend.audioFocus.held, isFalse);
    });
  });

  group('system focus', () {
    test('an interruption pauses the owner and its end resumes it', () async {
      final lease = pool.lease(a)..play();
      await settle();

      backend.audioFocus.emit(AudioFocusChange.interrupted);
      await settle();
      expect(lease.state.value.playing, isFalse);
      expect(backend.audioFocus.held, isTrue);

      backend.audioFocus.emit(AudioFocusChange.gained);
      await settle();
      expect(lease.state.value.playing, isTrue);
      expect(pool.soundOwner, a);
    });

    test('a player paused by the user is not resumed after a call', () async {
      final lease = pool.lease(a)..play();
      await settle();
      backend.audioFocus.emit(AudioFocusChange.interrupted);
      await settle();
      lease.pause();

      backend.audioFocus.emit(AudioFocusChange.gained);
      await settle();
      expect(lease.state.value.playing, isFalse);
    });

    test('losing focus to another app pauses for good', () async {
      final lease = pool.lease(a)..play();
      await settle();

      backend.audioFocus.emit(AudioFocusChange.lost);
      await settle();
      expect(lease.state.value.playing, isFalse);
      expect(pool.soundOwner, isNull);

      backend.audioFocus.emit(AudioFocusChange.gained);
      await settle();
      expect(lease.state.value.playing, isFalse);
    });

    test('headphones coming out pause the owner', () async {
      final lease = pool.lease(a)..play();
      await settle();

      backend.audioFocus.emit(AudioFocusChange.outputRemoved);
      await settle();
      expect(lease.state.value.playing, isFalse);
      expect(backend.audioFocus.held, isFalse);
    });

    test('a muted player ignores focus changes', () async {
      final lease = pool.lease(a)
        ..setVolume(0)
        ..play();
      await settle();

      backend.audioFocus.emit(AudioFocusChange.lost);
      await settle();
      expect(lease.state.value.playing, isTrue);
    });
  });

  group('leaving the screen', () {
    test('without a host callback the owner pauses', () async {
      final lease = pool.lease(a)..play();
      final view = lease.attachView();
      await settle();

      view.detach();
      await settle();

      expect(lease.state.value.playing, isFalse);
    });

    test('with a host callback the host decides', () async {
      pool.dispose();
      pool = makePool(hostDecides: true);
      final lease = pool.lease(a)..play();
      final view = lease.attachView();
      await settle();

      view.detach();
      await settle();

      expect(leftScreen, [a]);
      expect(lease.state.value.playing, isTrue);
    });

    test(
      'a hand-off to another view in the same turn is not a leave',
      () async {
        pool.dispose();
        pool = makePool(hostDecides: true);
        final bubble = pool.lease(a)..play();
        final bubbleView = bubble.attachView();
        await settle();

        final viewer = pool.lease(a);
        final viewerView = viewer.attachView();
        bubbleView.detach();
        bubble.release();
        await settle();

        expect(leftScreen, isEmpty);
        expect(viewer.state.value.playing, isTrue);
        viewerView.detach();
      },
    );

    test('a muted player leaving the screen is not reported', () async {
      pool.dispose();
      pool = makePool(hostDecides: true);
      final lease = pool.lease(a)
        ..setVolume(0)
        ..play();
      final view = lease.attachView();
      await settle();

      view.detach();
      await settle();
      expect(leftScreen, isEmpty);
    });
  });
}
