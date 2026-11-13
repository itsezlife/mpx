import 'package:flutter/material.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player_example/local_media.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final media = await LocalMedia.start();
  runApp(PlayerExample(pool: PlayerPool(backend: media.backend)));
}

/// One clip with sound on the platform player, with play, pause, a seek bar
/// and loop; the stream button switches between the progressive file and
/// the HLS stream of the same clip.
class PlayerExample extends StatefulWidget {
  const PlayerExample({required this.pool, super.key});

  final PlayerPool pool;

  @override
  State<PlayerExample> createState() => _PlayerExampleState();
}

class _PlayerExampleState extends State<PlayerExample>
    with SingleTickerProviderStateMixin {
  late PlayerLease _lease = _leaseOf(LocalMedia.clip);
  // Repaints the seek bar every frame: the playhead is read, never pushed.
  late final AnimationController _ticker = AnimationController.unbounded(
    vsync: this,
  )..repeat(min: 0, max: 1, period: const Duration(seconds: 1));

  PlayerLease _leaseOf(MediaKey key) => widget.pool.lease(key)
    ..setLooping(looping: true)
    ..play();

  void _switch() {
    final next = _lease.key == LocalMedia.clip
        ? LocalMedia.stream
        : LocalMedia.clip;
    final previous = _lease;
    setState(() => _lease = _leaseOf(next));
    previous.release();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _lease.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(child: PlayerView(lease: _lease)),
          ValueListenableBuilder<PlayerState>(
            valueListenable: _lease.state,
            builder: (context, state, _) => Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  IconButton(
                    color: Colors.white,
                    icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
                    onPressed: state.playing ? _lease.pause : _lease.play,
                  ),
                  Expanded(
                    child: AnimatedBuilder(
                      animation: _ticker,
                      builder: (context, _) {
                        final total = state.duration?.inMilliseconds ?? 0;
                        final at = _lease.position.inMilliseconds;
                        return Slider(
                          value: total == 0 ? 0 : (at / total).clamp(0, 1),
                          onChanged: total == 0
                              ? null
                              : (value) => _lease.seekTo(
                                  Duration(
                                    milliseconds: (value * total).round(),
                                  ),
                                ),
                        );
                      },
                    ),
                  ),
                  IconButton(
                    color: _lease.key == LocalMedia.stream
                        ? Colors.white
                        : Colors.white38,
                    icon: const Icon(Icons.stream),
                    tooltip: 'HLS stream',
                    onPressed: _switch,
                  ),
                  IconButton(
                    color: state.looping ? Colors.white : Colors.white38,
                    icon: const Icon(Icons.repeat),
                    onPressed: () => _lease.setLooping(looping: !state.looping),
                  ),
                  Text(
                    state.phase.name,
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
