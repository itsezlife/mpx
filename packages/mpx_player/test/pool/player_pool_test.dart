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
}
