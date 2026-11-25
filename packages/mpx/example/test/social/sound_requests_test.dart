import 'dart:ui' show VoidCallback;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/sound_requests.dart';

void main() {
  test('every surface that listens hears a request for sound', () {
    final requests = SoundRequests();
    var feed = 0;
    var reels = 0;
    requests
      ..listen(() => feed++)
      ..listen(() => reels++)
      ..request();

    expect((feed, reels), (1, 1));
  });

  test('a surface that stopped listening is not told', () {
    final requests = SoundRequests();
    var heard = 0;
    final stop = requests.listen(() => heard++);

    stop();
    requests.request();

    expect(heard, 0);
  });

  test('a surface may stop listening while it is told', () {
    final requests = SoundRequests();
    late final VoidCallback stop;
    var heard = 0;
    stop = requests.listen(() {
      heard++;
      stop();
    });
    requests
      ..request()
      ..request();

    expect(heard, 1);
  });
}
