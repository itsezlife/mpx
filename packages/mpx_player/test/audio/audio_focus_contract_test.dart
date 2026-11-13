import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_player/testing.dart';

void main() {
  group('NoAudioFocus', () {
    AudioFocusContract.run(NoAudioFocus.new);
  });

  group('FakeAudioFocus', () {
    AudioFocusContract.run(FakeAudioFocus.new);
  });
}
