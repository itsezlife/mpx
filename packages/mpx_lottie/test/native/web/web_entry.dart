// Compiled to JavaScript by native_web_compile_test.dart, never run: it only has to
// name the value types the web path uses through the public barrel.
import 'package:mpx_lottie/src/binding/binding.dart';

void main() {
  const handle = LottieHandle(1);
  const info = LottieInfo(
    width: 1,
    height: 1,
    frameCount: 1,
    frameRate: 1,
    features: LottieFeatures.none,
  );
  const LottieLoadResult result = LottieLoaded(handle, info);
  const LottieLoadResult refused = LottieRejected(LottieRejection.malformed);
  // ignore: avoid_print
  print([result, refused, LottieAvailability.available, LottieRenderStatus.ok]);
}
