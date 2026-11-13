import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

void main() {
  const a = MediaKey.remote('a');

  late FakePlayerBackend backend;
  late PlayerPool pool;
  late List<MediaKey> leftScreen;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    backend = FakePlayerBackend();
    leftScreen = [];
    pool = PlayerPool(backend: backend, onSoundOwnerLeftScreen: leftScreen.add);
  });
  tearDown(() => pool.dispose());

  group('NoPictureInPicture', () {
    PictureInPictureContract.run(NoPictureInPicture.new);
  });

  group('FakePictureInPicture', () {
    PictureInPictureContract.run(FakePictureInPicture.new);
  });

  group('picture in picture', () {
    test('a player with an engine moves into it', () async {
      pool.lease(a).play();
      await settle();

      expect(pool.startPictureInPicture(a), isTrue);
      expect(pool.pictureInPicture.value, a);
      expect(backend.pictureInPicture.active.value, backend.latestFor(a));
    });

    test('a key without an engine does not', () {
      expect(pool.startPictureInPicture(a), isFalse);
      expect(pool.pictureInPicture.value, isNull);
    });

    test('an unsupported platform does not', () async {
      backend.pictureInPicture.supported = false;
      pool.lease(a).play();
      await settle();

      expect(pool.startPictureInPicture(a), isFalse);
    });

    test('the window counts as a view: leaving the screen waits', () async {
      final lease = pool.lease(a)..play();
      final view = lease.attachView();
      await settle();

      pool.startPictureInPicture(a);
      view.detach();
      await settle();

      expect(leftScreen, isEmpty);
      expect(lease.viewCount, 1);
    });

    test('closing the window with no view left asks the host', () async {
      final lease = pool.lease(a)..play();
      await settle();
      pool.startPictureInPicture(a);

      backend.pictureInPicture.end();
      await settle();

      expect(pool.pictureInPicture.value, isNull);
      expect(lease.viewCount, 0);
      expect(leftScreen, [a]);
    });

    test('stopping ends it', () async {
      pool.lease(a).play();
      await settle();
      pool
        ..startPictureInPicture(a)
        ..stopPictureInPicture();

      expect(pool.pictureInPicture.value, isNull);
    });

    test('releasing the engine ends it', () async {
      pool.budget = const PlayerBudget(active: 1, prepared: 0);
      final lease = pool.lease(a)..play();
      await settle();
      pool.startPictureInPicture(a);
      lease.release();
      pool.lease(const MediaKey.remote('b')).play();
      await settle();

      expect(pool.pictureInPicture.value, isNull);
    });
  });
}
