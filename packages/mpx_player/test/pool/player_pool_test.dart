import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

void main() {
  const a = MediaKey.remote('a');
  const b = MediaKey.remote('b');
  const c = MediaKey.remote('c');
  const d = MediaKey.remote('d');

  late FakePlayerBackend backend;
  late PlayerPool pool;

  setUp(() {
    backend = FakePlayerBackend();
    pool = PlayerPool(backend: backend);
  });
  tearDown(() => pool.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('leases', () {
    test('two leases of one key share one player', () async {
      final first = pool.lease(a)..play();
      final second = pool.lease(a);
      await settle();

      expect(backend.created, hasLength(1));
      expect(second.state.value.playing, isTrue);
      expect(identical(first.state, second.state), isTrue);
    });

    test('a lease holds no engine until it prepares or plays', () async {
      final lease = pool.lease(a);

      expect(backend.created, isEmpty);
      expect(lease.state.value.phase, PlayerPhase.idle);

      lease.prepare();
      await settle();

      expect(lease.state.value.phase, PlayerPhase.ready);
    });

    test('hand-off to a new lease keeps position and playback', () async {
      final bubble = pool.lease(a)..play();
      await settle();
      backend.latestFor(a)!.advance(const Duration(seconds: 7));

      final viewer = pool.lease(a);
      bubble.release();

      expect(viewer.position, const Duration(seconds: 7));
      expect(viewer.state.value.playing, isTrue);
      expect(backend.created, hasLength(1));
    });

    test(
      'the last lease leaving pauses the player and keeps it warm',
      () async {
        final lease = pool.lease(a)..play();
        await settle();
        backend.latestFor(a)!.advance(const Duration(seconds: 4));

        lease.release();

        expect(backend.latestFor(a)!.state.value.playing, isFalse);
        final again = pool.lease(a);
        expect(again.position, const Duration(seconds: 4));
        expect(again.state.value.phase, PlayerPhase.ready);
        expect(backend.created, hasLength(1));
      },
    );

    test('a released lease is silent and its commands do nothing', () async {
      final lease = pool.lease(a)..prepare();
      await settle();
      lease
        ..release()
        ..release()
        ..play();

      expect(backend.latestFor(a)!.state.value.playing, isFalse);
      expect(lease.isReleased, isTrue);
    });

    test('commands reach the engine', () async {
      final lease = pool.lease(a)
        ..prepare()
        ..setSpeed(2)
        ..setLooping(looping: true)
        ..setVolume(0.5);
      await settle();
      lease.seekTo(const Duration(seconds: 3));

      final state = lease.state.value;
      expect(state.speed, 2);
      expect(state.looping, isTrue);
      expect(state.volume, 0.5);
      expect(lease.position, const Duration(seconds: 3));
    });

    test('views attach and detach; the count is per player', () {
      final first = pool.lease(a);
      final second = pool.lease(a);
      final one = first.attachView();
      final two = second.attachView();

      expect(first.viewCount, 2);
      one
        ..detach()
        ..detach();
      expect(second.viewCount, 1);
      two.detach();
      expect(first.viewCount, 0);
    });
  });

  group('a viewer opened and closed in quick turns', () {
    test('keeps one engine, attached and playing, through every turn and '
        'speed change', () async {
      PlayerLease? open;
      for (var turn = 0; turn < 6; turn++) {
        final lease = pool.lease(a)
          ..setSpeed(turn.isEven ? 2 : 0.5)
          ..seekTo(Duration(seconds: turn))
          ..play();
        // The last viewer lets go after the next one took the player.
        open?.release();
        open = lease;
        await settle();
        lease.setSpeed(1.5);
        await settle();
      }

      expect(backend.created, hasLength(1));
      final engine = backend.created.single;
      expect(engine.isDisposed, isFalse);
      expect(open!.state.value.playing, isTrue);
      expect(open.state.value.phase, PlayerPhase.ready);
      open.release();
    });
  });

  group('a failed player', () {
    test('keeps its error through a pause, a speed change and the release '
        'of its last lease', () async {
      final lease = pool.lease(a)..play();
      await settle();
      final error = StateError('the platform player stopped');
      backend.latestFor(a)!.fail(error);
      await settle();
      expect(lease.state.value.phase, PlayerPhase.failed);

      lease
        ..setSpeed(0.5)
        ..pause();
      expect(lease.state.value.phase, PlayerPhase.failed);
      expect(lease.state.value.error, same(error));

      lease.release();
    });

    test('a state copied with another phase drops the error; one that stays '
        'failed keeps it', () {
      final failed = const PlayerState().copyWith(
        phase: PlayerPhase.failed,
        error: 'broken',
      );

      expect(failed.copyWith(playing: false).error, 'broken');
      expect(failed.copyWith(speed: 2).phase, PlayerPhase.failed);
      expect(failed.copyWith(phase: PlayerPhase.idle).error, isNull);
    });
  });

  group('budget', () {
    test('evicts the coldest prepared player past the budget', () async {
      pool.budget = const PlayerBudget(active: 1, prepared: 2);
      final leaseA = pool.lease(a)..prepare();
      await settle();
      pool.lease(b).prepare();
      await settle();
      pool.lease(c).prepare();
      await settle();

      // Three prepared, none playing: the budget holds three in all.
      expect(backend.live, hasLength(3));

      pool.lease(d).prepare();
      await settle();

      expect(backend.latestFor(a)!.isDisposed, isTrue);
      expect(leaseA.state.value.phase, PlayerPhase.idle);
      expect(backend.live.map((e) => e.key), unorderedEquals([b, c, d]));
    });

    test('use makes a player warm again', () async {
      pool.budget = const PlayerBudget(active: 1, prepared: 1);
      final leaseA = pool.lease(a)..prepare();
      await settle();
      pool.lease(b).prepare();
      await settle();
      leaseA.seekTo(const Duration(seconds: 1));

      pool.lease(c).prepare();
      await settle();

      expect(backend.latestFor(b)!.isDisposed, isTrue);
      expect(backend.latestFor(a)!.isDisposed, isFalse);
    });

    test('a player with a view is evicted after those without', () async {
      pool.budget = const PlayerBudget(active: 1, prepared: 1);
      pool.lease(a)
        ..prepare()
        ..attachView();
      await settle();
      pool.lease(b).prepare();
      await settle();

      pool.lease(c).prepare();
      await settle();

      expect(backend.latestFor(b)!.isDisposed, isTrue);
      expect(backend.latestFor(a)!.isDisposed, isFalse);
    });

    test('unleased warm players go before leased ones', () async {
      pool.budget = const PlayerBudget(active: 1, prepared: 1);
      final leaseA = pool.lease(a)..prepare();
      await settle();
      pool.lease(b).prepare();
      await settle();
      leaseA.release();
      // a was used last (the release), but nobody holds it any more.

      pool.lease(c).prepare();
      await settle();

      expect(backend.latestFor(a)!.isDisposed, isTrue);
      expect(backend.latestFor(b)!.isDisposed, isFalse);
    });

    test('an evicted player prepares again from its position', () async {
      pool.budget = const PlayerBudget(active: 1, prepared: 0);
      final leaseA = pool.lease(a)..prepare();
      await settle();
      leaseA.seekTo(const Duration(seconds: 9));
      pool.lease(b).prepare();
      await settle();
      expect(leaseA.state.value.phase, PlayerPhase.idle);
      expect(leaseA.position, const Duration(seconds: 9));

      leaseA.prepare();
      await settle();

      expect(leaseA.state.value.phase, PlayerPhase.ready);
      expect(leaseA.position, const Duration(seconds: 9));
      expect(backend.created.where((e) => e.key == a), hasLength(2));
    });

    test('playing past the active count pauses the coldest player', () async {
      pool.budget = const PlayerBudget(active: 1, prepared: 2);
      final first = pool.lease(a)..play();
      await settle();
      final second = pool.lease(b)..play();
      await settle();

      expect(first.state.value.playing, isFalse);
      expect(first.state.value.phase, PlayerPhase.ready);
      expect(second.state.value.playing, isTrue);
    });

    test('shrinking the budget evicts at once', () async {
      pool.lease(a).prepare();
      await settle();
      pool.lease(b).prepare();
      await settle();

      pool.budget = const PlayerBudget(active: 1, prepared: 0);

      expect(backend.live, hasLength(1));
    });
  });

  test('dispose releases every engine and refuses new leases', () async {
    pool.lease(a).prepare();
    await settle();

    pool.dispose();

    expect(backend.live, isEmpty);
    expect(() => pool.lease(b), throwsStateError);
  });

  group('no decoder free', () {
    const busy = PlayerDecoderBusy('decoder init failed');

    test(
      'a player off screen lets its engine go and waits, not failed',
      () async {
        pool.lease(a).prepare();
        await settle();
        backend.latestFor(a)!.fail(busy);
        await settle();

        final lease = pool.lease(a);
        expect(lease.state.value.phase, isNot(PlayerPhase.failed));
        expect(backend.latestFor(a)!.isDisposed, isTrue);
        expect(backend.live.where((e) => e.key == a), isEmpty);
      },
    );

    test('a player on screen takes the decoders of the players off screen '
        'and starts again once', () async {
      final shown = pool.lease(a);
      final view = shown.attachView();
      addTearDown(view.detach);
      shown.prepare();
      final ahead = pool.lease(b)..prepare();
      final playingAway = pool.lease(c)..play();
      await settle();
      final first = backend.latestFor(a)!;

      first.fail(busy);
      await settle();

      expect(first.isDisposed, isTrue);
      final again = backend.latestFor(a)!;
      expect(identical(again, first), isFalse, reason: 'started again');
      expect(again.isDisposed, isFalse);
      expect(shown.state.value.phase, isNot(PlayerPhase.failed));
      expect(ahead.state.value.holdsEngine, isFalse, reason: 'let go');
      expect(
        backend.latestFor(c)!.isDisposed,
        isFalse,
        reason: 'one that plays keeps its decoder',
      );
      expect(playingAway.state.value.playing, isTrue);
    });

    test('on screen and busy again after its second start, it fails', () async {
      final slow = FakePlayerBackend(autoPrepare: false);
      final pool = PlayerPool(backend: slow);
      addTearDown(pool.dispose);
      final backend = slow;
      final shown = pool.lease(a);
      final view = shown.attachView();
      addTearDown(view.detach);
      shown.prepare();
      await settle();
      backend.latestFor(a)!.fail(busy);
      await settle();
      backend.latestFor(a)!.fail(busy);
      await settle();

      expect(shown.state.value.phase, PlayerPhase.failed);
      expect(shown.state.value.error, busy);
    });

    test('ready again, a later busy decoder gets another start', () async {
      final shown = pool.lease(a);
      final view = shown.attachView();
      addTearDown(view.detach);
      shown.prepare();
      await settle();
      backend.latestFor(a)!.fail(busy);
      await settle();
      expect(shown.state.value.phase, PlayerPhase.ready);
      backend.latestFor(a)!.fail(busy);
      await settle();
      expect(shown.state.value.phase, isNot(PlayerPhase.failed));
    });
  });
}
