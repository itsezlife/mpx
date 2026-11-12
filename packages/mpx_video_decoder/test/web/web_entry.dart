// Compiled to JavaScript by web_compile_test.dart, never run: it only has to
// build the neutral path through the public barrel and the browser element
// port behind package:mpx_video_decoder/web.dart.
import 'package:mpx_video_decoder/mpx_video_decoder.dart';
import 'package:mpx_video_decoder/web.dart';

void main() {
  // The web engine and its browser port: built, never started.
  // ignore: avoid_print
  print([
    WebVideoEngine(createPort: JsVideoElementPort.create),
    VideoDecoder,
    VideoFrameScheduler,
    VideoFrameAtlas.create,
  ]);
}
