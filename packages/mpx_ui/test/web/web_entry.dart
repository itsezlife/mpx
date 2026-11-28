// Compiled to JavaScript by web_compile_test.dart, never run: it only has to
// build the UI's public barrel and the player's web-safe library, which a
// web host imports (neither may reach the bytes cache's native reader).
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

void main() {
  // ignore: avoid_print
  print([LibraryPlayerSources.of, PlayerSource.local, PlayerPool]);
}
