import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/backend/player_backend.dart';
import 'package:mpx_player/src/player/player_state.dart';

/// What a [PlayerEngine] contract run needs besides the backend: media that
/// plays, media that does not, and a way to let the engine react.
final class PlayerEngineHarness {
  /// Creates a harness.
  ///
  /// [playable] must be at least [minimumDuration] long; [settle] lets the
  /// engine's work run once (a microtask turn for a fake, a short wait for a
  /// native engine).
  const PlayerEngineHarness({
    required this.backend,
    required this.playable,
    required this.unplayable,
    required this.settle,
    this.attempts = 200,
  });

  /// The backend under test.
  final PlayerBackend backend;

  /// Media that plays.
  final MediaKey playable;

  /// Media that cannot play.
  final MediaKey unplayable;

  /// Lets the engine's pending work run.
  final Future<void> Function() settle;

  /// How many [settle]s a test waits for a state before it fails.
  final int attempts;

  /// The shortest [playable] media the suite works with.
  static const Duration minimumDuration = Duration(seconds: 10);
}

/// The contract every [PlayerEngine] meets; see its documentation.
abstract final class PlayerEngineContract {
  /// Runs it as a test group. [create] builds a fresh harness for each test.
  static void run(PlayerEngineHarness Function() create) {
    group('PlayerEngine contract', () {
      late PlayerEngineHarness harness;
      final engines = <PlayerEngine>[];

      setUp(() => harness = create());
      tearDown(() {
        for (final engine in engines) {
          engine.dispose();
        }
        engines.clear();
      });

      PlayerEngine engineFor(MediaKey key) {
        final engine = harness.backend.create(key);
        engines.add(engine);
        return engine;
      }

      Future<void> until(
        PlayerEngine engine,
        bool Function(PlayerState state) done,
      ) async {
        for (var i = 0; i < harness.attempts; i++) {
          if (done(engine.state.value)) return;
          await harness.settle();
        }
        fail('Engine never reached the state; last: ${engine.state.value}');
      }

      Future<PlayerEngine> prepared({Duration startAt = Duration.zero}) async {
        final engine = engineFor(harness.playable)..prepare(startAt: startAt);
        await until(engine, (state) => state.phase == PlayerPhase.ready);
        return engine;
      }

      test('starts idle, holding no texture', () {
        final engine = engineFor(harness.playable);

        expect(engine.state.value.phase, PlayerPhase.idle);
        expect(engine.state.value.textureId, isNull);
        expect(engine.position, Duration.zero);
      });

      test('prepares to ready with a texture, a size and a duration', () async {
        final engine = await prepared();
        final state = engine.state.value;

        expect(state.textureId, isNotNull);
        expect(state.videoSize, isNotNull);
        expect(
          state.duration,
          greaterThanOrEqualTo(PlayerEngineHarness.minimumDuration),
        );
        expect(state.playing, isFalse);
      });

      test('passes through preparing', () {
        final engine = engineFor(harness.playable)..prepare();

        expect(engine.state.value.phase, PlayerPhase.preparing);
      });

      test('starts where it is asked to', () async {
        final engine = await prepared(startAt: const Duration(seconds: 3));

        expect(engine.position, const Duration(seconds: 3));
      });

      test('play and pause set and clear the wish to play', () async {
        final engine = await prepared();

        engine.play();
        await until(engine, (state) => state.playing);
        engine.pause();
        await until(engine, (state) => !state.playing);
      });

      test('seeks, clamped to the media', () async {
        final engine = await prepared();

        engine.seekTo(const Duration(seconds: 4));
        await harness.settle();
        expect(engine.position, const Duration(seconds: 4));

        engine.seekTo(const Duration(days: 1));
        await harness.settle();
        expect(engine.position, engine.state.value.duration);
      });

      test('a seek while preparing applies once ready', () async {
        final engine = engineFor(harness.playable)
          ..prepare()
          ..seekTo(const Duration(seconds: 2));
        await until(engine, (state) => state.phase == PlayerPhase.ready);

        expect(engine.position, const Duration(seconds: 2));
      });

      test('reports speed, looping and volume', () async {
        final engine = await prepared();

        engine
          ..setSpeed(1.5)
          ..setLooping(looping: true)
          ..setVolume(0.25);
        await until(
          engine,
          (state) =>
              state.speed == 1.5 && state.looping && state.volume == 0.25,
        );
      });

      test('media that cannot play fails with an error', () async {
        final engine = engineFor(harness.unplayable)..prepare();
        await until(engine, (state) => state.phase == PlayerPhase.failed);

        expect(engine.state.value.error, isNotNull);
        expect(engine.state.value.textureId, isNull);
      });

      test('is silent after dispose, and dispose is idempotent', () async {
        final engine = await prepared();
        var heard = 0;
        engine.state.addListener(() => heard++);

        engine
          ..dispose()
          ..dispose()
          ..play()
          ..seekTo(const Duration(seconds: 1));
        await harness.settle();

        expect(heard, 0);
      });
    });
  }
}
